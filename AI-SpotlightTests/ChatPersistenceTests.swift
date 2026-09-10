import Foundation
import XCTest
@testable import Enigma

final class ChatPersistenceTests: XCTestCase {
  func testStoreKeepsFiveMostRecentlyActiveChatsInDescendingOrder() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatSessionStore(applicationSupportDirectory: root)
    let epoch = Date(timeIntervalSince1970: 0)
    let sessions = (0..<6).map { index in
      ChatSession(
        title: "Chat \(index)",
        createdAt: epoch,
        lastActivityAt: epoch.addingTimeInterval(TimeInterval(index))
      )
    }

    try store.save(sessions)

    XCTAssertEqual(store.load().map(\.title), ["Chat 5", "Chat 4", "Chat 3", "Chat 2", "Chat 1"])
  }

  func testStoreRecoversToAnEmptyArchiveWhenJSONIsUnreadable() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "AI Spotlight", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: directory.appending(path: "chats.json"))

    XCTAssertEqual(ChatSessionStore(applicationSupportDirectory: root).load(), [])
  }

  func testBundledModelManifestHasValidDownloadMetadata() throws {
    XCTAssertFalse(LocalModelManifest.bundled.models.isEmpty)
    for model in LocalModelManifest.bundled.models {
      XCTAssertNoThrow(try model.validate())
    }
  }

  func testImagePreviewIsExcludedFromEncodedMessages() throws {
    var message = ChatMessage(role: .user, content: "Describe this image")
    message.imagePreview = Data("session-only image bytes".utf8)
    let data = try JSONEncoder().encode(message)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["id", "role", "content", "createdAt"])
    let restored = try JSONDecoder().decode(ChatMessage.self, from: data)
    XCTAssertEqual(restored.content, message.content)
    XCTAssertNil(restored.imagePreview)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "ChatPersistenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
