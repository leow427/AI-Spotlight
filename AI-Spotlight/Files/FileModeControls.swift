import SwiftUI

struct FileModeToolButton: View {
  @ObservedObject var files: FileModeCoordinator
  let isBusy: Bool
  let activate: () -> Void
  var body: some View {
    if files.selection != nil {
      Button(action: activate) {
        Image("FileMode").renderingMode(.template).resizable().scaledToFit()
          .foregroundStyle(Color.pink).frame(width: 22, height: 22).padding(4)
          .background(Color.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
      }
      .buttonStyle(.plain).disabled(isBusy || files.isPicking || files.isWorking)
      .padding(.leading, 10)
      .accessibilityLabel("File Mode").accessibilityValue("On")
      .help("Attach another file or folder · ⇧⌥F")
    }
  }
}

struct FileModeAttachmentView: View {
  @ObservedObject var files: FileModeCoordinator
  let access: FileAccessLevel
  let isCloud: Bool
  let isBusy: Bool
  let useCodex: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let selection = files.selection {
        ForEach(selection.attachments) { attachment in
          HStack(spacing: 8) {
            Image(systemName: attachment.isDirectory ? "folder" : "doc").foregroundStyle(.pink)
            Text("\(attachment.name) — \(access.rawValue)").font(.caption.weight(.medium)).lineLimit(1)
            Spacer(minLength: 4)
            Button { files.remove(id: attachment.id) } label: { Image(systemName: "xmark.circle.fill") }
              .buttonStyle(.plain).accessibilityLabel("Remove \(attachment.name)")
              .disabled(isBusy || files.isWorking)
          }
        }
        if access == .readOnly {
          HStack(spacing: 6) {
            Text(isCloud ? "Choose Codex to work with these files." : "Local can analyze files and suggest edits.")
              .font(.caption2).foregroundStyle(.secondary)
            Button("Use Codex", action: useCodex).font(.caption2).buttonStyle(.plain)
              .disabled(isBusy || files.isWorking)
          }
        } else {
          Text(isCloud ? "Relevant file contents may be sent to Codex when you send a request."
               : "This trusted local model can edit the attached files on this Mac.")
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
      if let error = files.error {
        Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
  }
}

struct FileChangeSummaryView: View {
  @ObservedObject var files: FileModeCoordinator
  let isBusy: Bool
  var body: some View {
    if let latest = files.visibleChanges.first {
      HStack(spacing: 10) {
        Text("\(latest.count) \(latest.count == 1 ? "file" : "files") changed").font(.caption)
        Button("Review") { files.review = latest }.buttonStyle(.plain)
        Button("Undo") { Task { await files.undo(latest) } }.buttonStyle(.plain)
          .disabled(isBusy || files.isWorking)
        if files.visibleChanges.count > 1 {
          Menu("Earlier changes") {
            ForEach(files.visibleChanges.dropFirst()) { change in
              Button("\(change.selection.displayName) · \(change.count) files") { files.review = change }
            }
          }.menuStyle(.borderlessButton).fixedSize()
        }
        Spacer(minLength: 0)
      }.font(.caption).padding(.horizontal, 4)
    }
  }
}

struct FileChangesReview: View {
  let changeSet: WorkspaceChangeSet
  let undo: () -> Void
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("\(changeSet.count) files changed").font(.title2.weight(.semibold))
          Text(changeSet.selection.displayName).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(changeSet.changes.filter { $0.before != $0.after }) { change in
            DisclosureGroup("\(change.kind) · \(change.path)") {
              VStack(alignment: .leading, spacing: 8) {
                preview("Before", data: change.before.data)
                preview("After", data: change.after.data)
              }.padding(.top, 8)
            }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
          }
        }
      }
      HStack {
        Text("Undo restores the files to how they were before this task.").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Undo Changes", action: undo)
      }
    }.padding(24).frame(width: 660, height: 480)
  }
  private func preview(_ title: String, data: Data?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption.weight(.semibold))
      Text(data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.prefix(12_000)) }
           ?? (data == nil ? "File does not exist" : "Binary file"))
        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if (data?.count ?? 0) > 12_000 { Text("Preview shortened. The full file is saved for Undo.").font(.caption2).foregroundStyle(.secondary) }
    }
  }
}

struct FileModeDialogs: ViewModifier {
  @ObservedObject var files: FileModeCoordinator
  @Binding var isCloudConsentPresented: Bool
  let isBusy: Bool
  let useCodex: () -> Void

  private var deletionPresented: Binding<Bool> {
    Binding(get: { files.deletionPath != nil }, set: { if !$0 { files.answerDeletion(false) } })
  }

  func body(content: Content) -> some View {
    content
      .sheet(item: $files.review) { change in
        FileChangesReview(changeSet: change) { Task { await files.undo(change) } }
      }
      .alert("Use Codex for these files?", isPresented: $isCloudConsentPresented) {
        Button("Use Codex", action: useCodex)
        Button("Keep Local", role: .cancel) { }
      } message: {
        Text("Codex can edit the attached files. Relevant file contents may be sent to the cloud when you send your next request. Your current local task will not be sent automatically.")
      }
      .alert("Delete this file?", isPresented: deletionPresented) {
        Button("Delete", role: .destructive) { files.answerDeletion(true) }
        Button("Keep File", role: .cancel) { files.answerDeletion(false) }
      } message: {
        Text("\(files.deletionPath ?? "") will be deleted from your attached workspace. You can restore it with Undo.")
      }
  }
}

struct FileRecoveryMenu: View {
  @ObservedObject var files: FileModeCoordinator
  @State private var selectedChange: WorkspaceChangeSet?
  var body: some View {
    VStack(alignment: .leading) {
      if !files.changes.isEmpty {
        Menu("Review Saved File Changes") {
          ForEach(files.changes) { change in
            Button("\(change.selection.displayName) · \(change.count) files") { selectedChange = change }
          }
        }.menuStyle(.borderlessButton).fixedSize()
      }
    }
    .sheet(item: $selectedChange) { change in
      VStack(alignment: .leading) {
        FileChangesReview(changeSet: change) {
          Task {
            await files.undo(change)
            if !files.changes.contains(where: { $0.id == change.id }) { selectedChange = nil }
          }
        }.disabled(files.isWorking)
        if let error = files.error { Text(error).font(.caption).foregroundStyle(.orange).padding() }
      }
    }
  }
}
