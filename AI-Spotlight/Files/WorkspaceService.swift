import Foundation
import CryptoKit
import PDFKit

struct WorkspaceFileState: Codable, Equatable, Sendable {
  let data: Data?
  let mode: UInt16
  var attributes: [String: Data] = [:]
  var permissions: WorkspaceFilePermissions? = nil
  var createdBySpotlight: Bool? = nil
}

struct WorkspaceChange: Codable, Equatable, Sendable, Identifiable {
  var id: String { path }
  let path: String
  let before: WorkspaceFileState
  var after: WorkspaceFileState
  var absolutePath: String? = nil
  var kind: String { before.data == nil ? "Created" : after.data == nil ? "Deleted" : "Edited" }
}

struct WorkspaceChangeSet: Codable, Equatable, Sendable, Identifiable {
  let id: UUID
  let selection: WorkspaceSelection
  var changes: [WorkspaceChange]
  var conversationID: UUID? = nil
  var isUndone = false
  var count: Int { changes.filter { $0.before != $0.after }.count }
}

enum WorkspaceMutation: Sendable {
  case create(path: String, content: String)
  case write(path: String, content: String)
  case patch(path: String, old: String, new: String)
  case move(from: String, to: String)
  case delete(path: String)
}

/// Shared authority for both agents. No model or provider gets a FileManager or shell handle.
/// Each journal is persisted before any write; the pending after-image makes crash recovery
/// possible even when the app exits between a rename and the final journal update.
actor WorkspaceService {
  nonisolated let selection: WorkspaceSelection
  nonisolated let accessLevel: FileAccessLevel
  private let access: WorkspaceAccess
  private let journalDirectory: URL
  private var journal: WorkspaceChangeSet
  private var active = true
  private var mutationInProgress = false
  private let writePolicy: WorkspaceWritePolicy
  private let knownOrigins: [String: Set<Data>]
  private let failureAfterWrite: (@Sendable (Int) throws -> Void)?

  init(selection: WorkspaceSelection, accessLevel: FileAccessLevel,
       journalDirectory: URL = WorkspaceService.defaultJournalDirectory,
       conversationID: UUID? = nil,
       writePolicy: WorkspaceWritePolicy = .cloud,
       failureAfterWrite: (@Sendable (Int) throws -> Void)? = nil) throws {
    self.selection = selection
    self.accessLevel = accessLevel
    access = try WorkspaceAccess(selection: selection)
    self.journalDirectory = journalDirectory
    journal = WorkspaceChangeSet(id: UUID(), selection: selection, changes: [], conversationID: conversationID)
    self.failureAfterWrite = failureAfterWrite
    self.writePolicy = writePolicy
    var origins: [String: Set<Data>] = [:]
    // Read only app-owned provenance; never resolve or reopen historical attachment bookmarks.
    for record in Self.savedChanges(in: journalDirectory) {
      for change in record.changes where change.after.createdBySpotlight == true {
        if let path = change.absolutePath, let data = change.after.data {
          origins[path, default: []].insert(Data(SHA256.hash(data: data)))
        }
      }
    }
    knownOrigins = origins
  }

  static var defaultJournalDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "AI Spotlight/File Changes", directoryHint: .isDirectory)
  }

  var snapshotURL: URL { journalDirectory.appendingPathComponent(journal.id.uuidString + ".json") }
  func changeSet() -> WorkspaceChangeSet { journal }
  func revoke() { active = false }
  func finish() -> WorkspaceChangeSet { active = false; return journal }

  private func checkActive() throws {
    guard active else { throw FileModeError.inactive }
    try Task.checkCancellation()
  }

  func readFile(_ path: String, offset: Int = 0, limit: Int = 16_000) throws -> String {
    try checkActive()
    guard offset >= 0, offset <= WorkspaceAccess.fileLimit, (1...32_000).contains(limit) else {
      throw FileModeError.invalidArguments
    }
    return String(try textFile(path).dropFirst(offset).prefix(limit))
  }

  private func textFile(_ path: String) throws -> String {
    let data = try access.read(access.location(path))
    let text: String
    if path.lowercased().hasSuffix(".pdf") {
      guard let document = PDFDocument(data: data), document.pageCount <= 200,
            let extracted = document.string else { throw FileModeError.unsafeFile }
      text = extracted
    } else {
      guard !data.contains(0), let decoded = String(data: data, encoding: .utf8) else {
        throw FileModeError.operation("This file is not readable text or a supported PDF. Choose a text export to analyze it.")
      }
      text = decoded
    }
    return text
  }

  func metadata(_ path: String) throws -> CodexValue {
    try checkActive()
    guard let info = try access.info(access.location(path)) else { throw FileModeError.invalidArguments }
    return .object(["path": .string(path), "directory": .bool(info.st_mode & 0o170000 == 0o040000),
      "bytes": .number(Double(info.st_size)), "modifiedAt": .number(Double(info.st_mtimespec.tv_sec))])
  }

  func listFiles(_ path: String = ".", limit: Int = 200) throws -> [String] {
    try checkActive()
    guard (1...500).contains(limit) else { throw FileModeError.invalidArguments }
    if path == ".", selection.attachments.count > 1 || !selection.attachments[0].isDirectory {
      return selection.attachments.indices.map {
        selection.mountName(at: $0) + (selection.attachments[$0].isDirectory ? "/" : "")
      }
    }
    let location = try access.location(path)
    guard let info = try access.info(location) else { throw FileModeError.invalidArguments }
    if info.st_mode & 0o170000 != 0o040000 { return [path] }
    var result: [String] = []
    for name in try access.names(location) {
      let child = path == "." ? name : path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + name
      // Links are omitted, rather than resolving even internal links and granting aliases.
      guard let info = try? access.info(access.location(child)) else { continue }
      result.append(child + (info.st_mode & 0o170000 == 0o040000 ? "/" : ""))
      if result.count >= limit { break }
    }
    return result
  }

  func searchFiles(_ query: String, path: String = ".", namesOnly: Bool = false) throws -> [String] {
    try checkActive()
    guard !query.isEmpty, query.count <= 512 else { throw FileModeError.invalidArguments }
    var pending = [path]
    var matches: [String] = []
    var visited = 0
    var readBytes = 0
    while let next = pending.popLast(), visited < 2_000, matches.count < 100 {
      try checkActive()
      for entry in try listFiles(next, limit: 500) {
        visited += 1
        if visited > 2_000 || matches.count >= 100 { break }
        if entry.localizedCaseInsensitiveContains(query) { matches.append(entry) }
        if entry.hasSuffix("/") {
          let components = entry.split(separator: "/")
          if components.count < 16, ![".git", ".codex", ".agents", "node_modules", ".build"].contains(String(components.last ?? "")) {
            pending.append(String(entry.dropLast()))
          }
        } else if !namesOnly && readBytes < 4 * 1_024 * 1_024,
                  let text = try? textFile(entry) {
          let bounded = String(decoding: text.utf8.prefix(4 * 1_024 * 1_024 - readBytes), as: UTF8.self)
          readBytes += bounded.utf8.count
          for (index, line) in bounded.components(separatedBy: "\n").enumerated()
            where line.localizedCaseInsensitiveContains(query) {
            matches.append("\(entry):\(index + 1): \(line.prefix(240))")
            if matches.count >= 100 { break }
          }
        }
      }
    }
    return matches
  }

  func apply(_ mutations: [WorkspaceMutation],
             confirmDeletion: (@Sendable (String) async -> Bool)? = nil) async throws {
    try checkActive()
    guard !mutationInProgress else { throw FileModeError.conflict }
    mutationInProgress = true
    defer { mutationInProgress = false }
    guard accessLevel == .readWrite else { throw FileModeError.readOnly }
    guard !mutations.isEmpty, mutations.count <= 100 else { throw FileModeError.invalidArguments }
    var before: [String: WorkspaceFileState] = [:]
    var after: [String: WorkspaceFileState] = [:]
    func current(_ path: String) throws -> WorkspaceFileState {
      _ = try access.location(path, writing: true)
      if let value = after[path] { return value }
      let value = try state(path)
      if let previous = journal.changes.first(where: { $0.path == path }), value != previous.after {
        throw FileModeError.conflict
      }
      before[path] = value
      return value
    }
    for mutation in mutations {
      switch mutation {
      case .create(let path, let content):
        let value = try current(path)
        guard value.data == nil else { throw FileModeError.conflict }
        after[path] = WorkspaceFileState(data: Data(content.utf8), mode: 0o600, permissions: .newFile, createdBySpotlight: true)
      case .write(let path, let content):
        let value = try current(path)
        guard let existing = value.data, !existing.contains(0), String(data: existing, encoding: .utf8) != nil else {
          throw FileModeError.operation("Only UTF-8 text files can be replaced. Export this document as text to edit it safely.")
        }
        after[path] = WorkspaceFileState(data: Data(content.utf8), mode: value.mode, attributes: value.attributes, permissions: value.permissions, createdBySpotlight: value.createdBySpotlight)
      case .patch(let path, let old, let new):
        let value = try current(path)
        guard !old.isEmpty, let data = value.data, !data.contains(0), let text = String(data: data, encoding: .utf8),
              text.components(separatedBy: old).count == 2 else { throw FileModeError.invalidArguments }
        after[path] = WorkspaceFileState(data: Data(text.replacingOccurrences(of: old, with: new).utf8), mode: value.mode, attributes: value.attributes, permissions: value.permissions, createdBySpotlight: value.createdBySpotlight)
      case .move(let from, let to):
        guard from != to else { throw FileModeError.invalidArguments }
        let source = try current(from)
        guard source.data != nil, try current(to).data == nil else { throw FileModeError.conflict }
        after[to] = source
        after[from] = WorkspaceFileState(data: nil, mode: 0o600)
      case .delete(let path):
        let value = try current(path)
        guard value.data != nil else { throw FileModeError.invalidArguments }
        after[path] = WorkspaceFileState(data: nil, mode: 0o600)
      }
    }
    guard after.values.allSatisfy({ ($0.data?.count ?? 0) <= WorkspaceAccess.fileLimit }) else {
      throw FileModeError.tooLarge
    }
    let protectedPaths = try after.keys.sorted().filter { path in
      let classificationPath = access.absolutePath(try access.location(path, writing: true))
      let original = before[path]!
      let proposed = after[path]!
      // Classify both versions. A note cannot be rewritten as structured data, or moved into
      // a source/config path, to bypass a protected-write decision. New files have no provenance yet.
      let versions = [original.data, proposed.data].compactMap { $0 }
      return versions.contains { WorkspaceWriteClassifier.classify(path: classificationPath, data: $0,
        createdBySpotlight: original.createdBySpotlight == true) == .protectedWrite }
    }
    try await writePolicy.authorize(protectedPaths: protectedPaths)
    try checkActive()
    if let confirmDeletion {
      for case .delete(let path) in mutations {
        guard await confirmDeletion(path) else {
          throw FileModeError.operation("The user did not approve deleting this file. Keep it.")
        }
        try checkActive()
      }
    }
    let oldJournal = journal
    for path in after.keys.sorted() {
      if let index = journal.changes.firstIndex(where: { $0.path == path }) {
        journal.changes[index].after = after[path]!
      } else {
        journal.changes.append(WorkspaceChange(path: path, before: before[path]!, after: after[path]!,
          absolutePath: access.absolutePath(try access.location(path, writing: true))))
      }
    }
    guard journal.changes.reduce(0, { $0 + ($1.before.data?.count ?? 0) + ($1.after.data?.count ?? 0)
      + $1.before.attributes.values.reduce(0) { $0 + $1.count } + $1.after.attributes.values.reduce(0) { $0 + $1.count } }) <= 64 * 1_024 * 1_024 else {
      journal = oldJournal
      throw FileModeError.tooLarge
    }
    do { try persist() } catch { journal = oldJournal; throw error }
    var written: [String] = []
    do {
      for path in after.keys.sorted() {
        try checkActive()
        guard try state(path) == before[path] else { throw FileModeError.conflict }
        try restore(after[path]!, at: path)
        written.append(path)
        try failureAfterWrite?(written.count)
      }
    } catch {
      var rollbackFailed = false
      for path in written.reversed() {
        do {
          guard try state(path) == after[path] else { throw FileModeError.conflict }
          try restore(before[path]!, at: path)
        } catch { rollbackFailed = true }
      }
      if !rollbackFailed { journal = oldJournal; try persist() }
      if rollbackFailed {
        active = false
        throw FileModeError.operation("Some files could not be restored. Their recovery copies were kept. Use Review and Undo before continuing.")
      }
      throw error
    }
  }

  /// Undo uses the same authority and atomic replacement primitives, including after restart.
  /// Files already at their before-image are accepted after an interrupted operation.
  func undo(_ saved: WorkspaceChangeSet) throws -> WorkspaceChangeSet {
    guard !mutationInProgress else { throw FileModeError.conflict }
    guard saved.selection == selection, !saved.isUndone else { throw FileModeError.invalidArguments }
    var current: [String: WorkspaceFileState] = [:]
    for change in saved.changes {
      let value = try state(change.path)
      guard value == change.before || value == change.after else { throw FileModeError.conflict }
      current[change.path] = value
    }
    var restored: [WorkspaceChange] = []
    do {
      for change in saved.changes.reversed() {
        guard try state(change.path) == current[change.path] else { throw FileModeError.conflict }
        if current[change.path] != change.before {
          try restore(change.before, at: change.path)
          restored.append(change)
        }
      }
      var undone = saved
      undone.isUndone = true
      try persist(undone)
      return undone
    } catch {
      var rollbackFailed = false
      for change in restored.reversed() {
        do {
          guard try state(change.path) == change.before else { throw FileModeError.conflict }
          try restore(current[change.path]!, at: change.path)
        } catch { rollbackFailed = true }
      }
      if rollbackFailed { throw FileModeError.operation("Undo could not finish. Recovery copies were kept; review the affected files.") }
      throw error
    }
  }

  private func state(_ path: String) throws -> WorkspaceFileState {
    let location = try access.location(path, writing: true)
    guard let info = try access.info(location) else { return WorkspaceFileState(data: nil, mode: 0o600) }
    let data = try access.read(location)
    let known = knownOrigins[access.absolutePath(location)]?.contains(Data(SHA256.hash(data: data))) == true
      || journal.changes.contains { change in
        change.path == path && [change.before, change.after].contains { $0.createdBySpotlight == true && $0.data == data }
      }
    return WorkspaceFileState(data: data, mode: UInt16(info.st_mode & 0o777),
      attributes: try access.attributes(location), permissions: try access.permissions(location),
      createdBySpotlight: known ? true : nil)
  }

  private func restore(_ value: WorkspaceFileState, at path: String) throws {
    try access.replace(access.location(path, writing: true), data: value.data, mode: value.mode, attributes: value.attributes, permissions: value.permissions)
  }

  private func persist(_ value: WorkspaceChangeSet? = nil) throws {
    let value = value ?? journal
    try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let url = journalDirectory.appendingPathComponent(value.id.uuidString + ".json")
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.synchronize()
  }

  static func savedChanges(in directory: URL = defaultJournalDirectory) -> [WorkspaceChangeSet] {
    guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
    return urls.filter { $0.pathExtension == "json" }.compactMap {
      guard let data = try? Data(contentsOf: $0), data.count <= 100 * 1_024 * 1_024 else { return nil }
      return try? JSONDecoder().decode(WorkspaceChangeSet.self, from: data)
    }.filter { !$0.isUndone && $0.count > 0 }
  }
}
