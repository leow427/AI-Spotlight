import Foundation

enum WorkspaceWriteClass: String, Sendable { case safeWrite = "safe-write", protectedWrite = "protected-write" }

/// One host-owned classification for every backend and every mutation. Unknown formats default
/// to protected; model arguments cannot label a file safe or claim that the app created it.
enum WorkspaceWriteClassifier {
  static let documentExtensions: Set<String> = ["md", "markdown", "txt", "text"]
  static let noteNames: Set<String> = ["note", "notes", "plan", "plans", "checklist", "checklists", "todo", "readme"]
  static let sensitiveNames: Set<String> = ["agents.md", "claude.md", "gemini.md", "copilot-instructions.md"]

  static func classify(path: String, data: Data?, createdBySpotlight: Bool) -> WorkspaceWriteClass {
    let components = path.lowercased().split(separator: "/").map(String.init)
    guard let name = components.last else { return .protectedWrite }
    let stem = (name as NSString).deletingPathExtension
    if ["config", "configuration", "settings", "manifest", "package", "project", "database"].contains(stem)
      || components.dropLast().contains(where: { ["config", "configuration", "settings"].contains($0) }) {
      return .protectedWrite
    }
    // Credential/configuration names remain protected even when they have a document extension.
    if components.contains(where: { $0.hasPrefix(".") || sensitiveNames.contains($0)
      || ["secret", "credential", "password", "private-key", "private_key"].contains(where: $0.contains) }) {
      return .protectedWrite
    }
    guard let data, !data.contains(0), let text = String(data: data, encoding: .utf8) else { return .protectedWrite }
    if createdBySpotlight { return .safeWrite }
    let suffix = (name as NSString).pathExtension
    guard documentExtensions.contains(suffix) || noteNames.contains(name) else { return .protectedWrite }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("#!") || trimmed.hasPrefix("<?xml")
      || ((trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) && (try? JSONSerialization.jsonObject(with: data)) != nil) {
      return .protectedWrite
    }
    return .safeWrite
  }
}

enum FileEditingCloudAvailability: Equatable, Sendable {
  case available(modelID: String)
  case unavailable(reason: String)
}

enum ProtectedWriteNotice: Equatable, Sendable {
  case cloudRequired(paths: [String], modelID: String)
  case localFallback(paths: [String], reason: String)

  var paths: [String] {
    switch self { case .cloudRequired(let paths, _), .localFallback(let paths, _): paths }
  }
  var message: String {
    let names = paths.prefix(3).joined(separator: ", ") + (paths.count > 3 ? " and more" : "")
    switch self {
    case .cloudRequired:
      return "Protected edit: \(names). Use Codex to continue. Relevant file contents may be sent to the cloud after you approve and send the request."
    case .localFallback(_, let reason):
      return "Local fallback for \(names): \(reason) Local edits to protected files may be less reliable. Review the result; Undo is available."
    }
  }
}

actor FileEditingCloudProbe {
  private let check: WorkspaceWritePolicy.CloudCheck
  private var cached: FileEditingCloudAvailability?
  init(check: @escaping WorkspaceWritePolicy.CloudCheck) { self.check = check }
  func availability() async -> FileEditingCloudAvailability {
    if let cached { return cached }
    let value = await check()
    if !Task.isCancelled { cached = value }
    return value
  }
}

enum WorkspaceWritePolicy: Sendable {
  typealias CloudCheck = @Sendable () async -> FileEditingCloudAvailability
  case cloud
  case local(cloudAvailability: CloudCheck, notice: @Sendable (ProtectedWriteNotice) async -> Void)

  func authorize(protectedPaths: [String]) async throws {
    guard !protectedPaths.isEmpty, case .local(let availability, let notify) = self else { return }
    try Task.checkCancellation()
    let cloud = await availability()
    try Task.checkCancellation()
    switch cloud {
    case .available(let modelID):
      await notify(.cloudRequired(paths: protectedPaths, modelID: modelID))
      throw FileModeError.protectedWriteRequiresCloud
    case .unavailable(let reason):
      await notify(.localFallback(paths: protectedPaths, reason: reason))
    }
    try Task.checkCancellation()
  }
}
