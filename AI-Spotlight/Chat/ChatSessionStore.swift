import Foundation

struct ChatSessionStore: Sendable {
  static let maximumRetainedSessions = 5

  private let fileURL: URL

  init(applicationSupportDirectory: URL? = nil) {
    let directory = applicationSupportDirectory ?? FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "AI Spotlight", directoryHint: .isDirectory)
    fileURL = directory.appending(path: "chats.json")
  }

  func load() -> [ChatSession] {
    guard let data = try? Data(contentsOf: fileURL),
          let sessions = try? decoder.decode([ChatSession].self, from: data) else {
      return []
    }
    return normalized(sessions)
  }

  func save(_ sessions: [ChatSession]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try encoder.encode(normalized(sessions)).write(to: fileURL, options: .atomic)
  }

  private func normalized(_ sessions: [ChatSession]) -> [ChatSession] {
    Array(
      sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
        .prefix(Self.maximumRetainedSessions)
    )
  }

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
