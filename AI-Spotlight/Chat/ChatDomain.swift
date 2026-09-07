import Foundation

enum ChatMode: String, Codable, CaseIterable, Sendable, Identifiable {
  case auto
  case local
  case cloud

  var id: Self { self }

  var displayName: String { rawValue.capitalized }
}

struct Route: Codable, Sendable, Equatable {
  let mode: ChatMode
  let providerID: String
  let modelID: String
  let usesNetwork: Bool
}

struct ChatRequest: Sendable, Equatable {
  let sessionID: UUID
  let messages: [ChatMessage]
  let route: Route
  var image: PreparedScreenImage? = nil
  var allowsCloudImages = false
}

enum ChatEvent: Sendable, Equatable {
  case token(String)
  case completed
}

protocol ChatProvider: Sendable {
  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}

struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
  enum Role: String, Codable, Sendable {
    case user
    case assistant
  }

  let id: UUID
  let role: Role
  var content: String
  var searchSources: [WebSearchSource]?
  let createdAt: Date
  // Session-only UI data: never serialize screenshot pixels or send them as chat text.
  var imagePreview: Data? = nil
  var extendedThinking: Bool? = nil

  private enum CodingKeys: String, CodingKey {
    case id, role, content, searchSources, createdAt
  }

  init(id: UUID = UUID(), role: Role, content: String, createdAt: Date = .now, searchSources: [WebSearchSource]? = nil) {
    self.id = id
    self.role = role
    self.content = content
    self.searchSources = searchSources
    self.createdAt = createdAt
  }
}

struct ChatSession: Codable, Sendable, Equatable, Identifiable {
  let id: UUID
  var title: String
  var messages: [ChatMessage]
  let createdAt: Date
  var lastActivityAt: Date
  var workspace: WorkspaceSelection? = nil

  init(
    id: UUID = UUID(),
    title: String = "New Chat",
    messages: [ChatMessage] = [],
    createdAt: Date = .now,
    lastActivityAt: Date = .now
  ) {
    self.id = id
    self.title = title
    self.messages = messages
    self.createdAt = createdAt
    self.lastActivityAt = lastActivityAt
  }

  mutating func append(_ message: ChatMessage, at date: Date = .now) {
    messages.append(message)
    lastActivityAt = date
    if title == "New Chat", message.role == .user {
      title = Self.title(for: message.content)
    }
  }

  private static func title(for content: String) -> String {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "New Chat" }
    return String(trimmed.prefix(48))
  }
}
