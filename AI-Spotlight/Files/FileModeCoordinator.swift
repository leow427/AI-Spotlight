import AppKit
import Combine
import Foundation

@MainActor
protocol WorkspacePicking {
  func pick() async -> [URL]?
}

@MainActor
struct FinderWorkspacePicker: WorkspacePicking {
  static func panel() -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.title = "Choose files or a folder"
    panel.message = "File Mode can access only the locations you attach."
    panel.prompt = "Attach"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.resolvesAliases = true
    panel.canCreateDirectories = false
    return panel
  }

  func pick() async -> [URL]? {
    let panel = Self.panel()
    return await withCheckedContinuation { continuation in
      if let window = NSApp.keyWindow {
        panel.beginSheetModal(for: window) { result in
          continuation.resume(returning: result == .OK ? panel.urls : nil)
        }
      } else {
        panel.begin { result in continuation.resume(returning: result == .OK ? panel.urls : nil) }
      }
    }
  }
}

@MainActor
final class FileModeCoordinator: ObservableObject {
  enum Activation { case menu, keyboard }
  @Published private(set) var selection: WorkspaceSelection?
  @Published private(set) var isPicking = false
  @Published private(set) var isWorking = false
  @Published var error: String?
  @Published private(set) var changes: [WorkspaceChangeSet] = []
  @Published private(set) var deletionPath: String?
  @Published var review: WorkspaceChangeSet?
  @Published var conversationID: UUID?
  var visibleChanges: [WorkspaceChangeSet] {
    changes.filter { change in
      if let conversationID { return change.conversationID == conversationID }
      return selection != nil && change.selection == selection
    }
  }
  var onSelectionChange: ((WorkspaceSelection?) -> Void)?
  private let picker: any WorkspacePicking
  let journalDirectory: URL
  private var selectionRevision = UUID()
  private var deletionContinuation: CheckedContinuation<Bool, Never>?
  private var activeWorkspace: WorkspaceService?

  init(picker: any WorkspacePicking = FinderWorkspacePicker(),
       journalDirectory: URL = WorkspaceService.defaultJournalDirectory) {
    self.picker = picker
    self.journalDirectory = journalDirectory
    // Discovery reads app-owned recovery metadata only, never attached files.
    changes = WorkspaceService.savedChanges(in: journalDirectory)
  }

  func activate(from source: Activation) async {
    guard !isPicking, !isWorking else { return }
    isPicking = true
    let revision = selectionRevision
    defer { isPicking = false }
    guard let urls = await picker.pick(), !urls.isEmpty, selectionRevision == revision else { return }
    do {
      // Selecting more locations is an explicit additional grant. Deduplicate canonical URLs.
      var attachments = selection?.attachments ?? []
      for url in urls {
        let attachment = try WorkspaceAttachment.select(url)
        if !attachments.contains(where: { $0.url == attachment.url }) { attachments.append(attachment) }
      }
      guard attachments.count <= 16 else { throw FileModeError.invalidArguments }
      selection = WorkspaceSelection.normalized(attachments)
      selectionRevision = UUID()
      error = nil
      onSelectionChange?(selection)
    } catch { self.error = error.localizedDescription }
  }

  func remove(id: UUID) {
    guard !isWorking else { return }
    selectionRevision = UUID()
    let attachments = selection?.attachments.filter { $0.id != id } ?? []
    selection = attachments.isEmpty ? nil : WorkspaceSelection(attachments: attachments)
    error = nil
    onSelectionChange?(selection)
  }

  func restoreSelection(_ selection: WorkspaceSelection?) {
    cancelPendingDeletion()
    selectionRevision = UUID()
    self.selection = selection
    error = nil
    // Bookmark scopes open only when the user sends a File Mode request.
  }

  func begin(access: FileAccessLevel) throws -> AgentFileTools {
    guard let selection, !isWorking, !isPicking else { throw FileModeError.inactive }
    let workspace = try WorkspaceService(selection: selection, accessLevel: access, journalDirectory: journalDirectory, conversationID: conversationID)
    activeWorkspace = workspace
    isWorking = true
    error = nil
    return AgentFileTools(workspace: workspace, confirmDeletion: { [weak self] path in
      await self?.confirmDeletion(path) ?? false
    })
  }

  func finish(workspace: WorkspaceService) async {
    let changeSet = await workspace.finish()
    if changeSet.count > 0 {
      changes.removeAll { $0.id == changeSet.id }
      changes.insert(changeSet, at: 0)
    }
    if activeWorkspace === workspace {
      activeWorkspace = nil
      isWorking = false
      cancelPendingDeletion()
    }
  }

  func revoke() {
    cancelPendingDeletion()
    if let workspace = activeWorkspace { Task { await workspace.revoke() } }
  }

  func undo(_ changeSet: WorkspaceChangeSet) async {
    guard !isWorking else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      let workspace = try WorkspaceService(selection: changeSet.selection, accessLevel: .readWrite,
        journalDirectory: journalDirectory)
      _ = try await workspace.undo(changeSet)
      changes.removeAll { $0.id == changeSet.id }
      review = nil
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  private func confirmDeletion(_ path: String) async -> Bool {
    guard isWorking, deletionContinuation == nil, !Task.isCancelled else { return false }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        deletionPath = path
        deletionContinuation = continuation
      }
    } onCancel: { Task { @MainActor [weak self] in self?.cancelPendingDeletion() } }
  }

  func answerDeletion(_ approved: Bool) {
    let continuation = deletionContinuation
    deletionContinuation = nil
    deletionPath = nil
    continuation?.resume(returning: approved)
  }

  private func cancelPendingDeletion() { answerDeletion(false) }
}
