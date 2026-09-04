import Foundation
@testable import PrimaryAgent

final class ScreenTestCredentialStore: CloudCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [CloudProviderID: String]

  init(keys: [CloudProviderID: String] = [:]) {
    self.keys = keys
  }

  func apiKey(for provider: CloudProviderID) throws -> String? {
    access { keys[provider] }
  }

  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {
    access { keys[provider] = apiKey }
  }

  func removeAPIKey(for provider: CloudProviderID) throws {
    _ = access { keys.removeValue(forKey: provider) }
  }

  private func access<T>(_ operation: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return operation()
  }
}

final class ScreenTestTransport: CloudNetworkTransport, @unchecked Sendable {
  typealias DataHandler = @Sendable (URLRequest) async throws -> CloudDataResponse
  typealias StreamHandler = @Sendable (URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error>

  private let lock = NSLock()
  private let dataHandler: DataHandler
  private let streamHandler: StreamHandler
  private var storedDataRequests: [URLRequest] = []
  private var storedStreamRequests: [URLRequest] = []

  init(
    dataHandler: @escaping DataHandler = { _ in
      CloudDataResponse(data: Data(), statusCode: 200)
    },
    streamHandler: @escaping StreamHandler = { _ in
      AsyncThrowingStream { $0.finish() }
    }
  ) {
    self.dataHandler = dataHandler
    self.streamHandler = streamHandler
  }

  var dataRequests: [URLRequest] { access { storedDataRequests } }
  var streamRequests: [URLRequest] { access { storedStreamRequests } }

  func data(for request: URLRequest) async throws -> CloudDataResponse {
    access { storedDataRequests.append(request) }
    return try await dataHandler(request)
  }

  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    access { storedStreamRequests.append(request) }
    return streamHandler(request)
  }

  private func access<T>(_ operation: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return operation()
  }
}

private final class CloudCancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded = false

  var wasRecorded: Bool { access { recorded } }

  func record() {
    access { recorded = true }
  }

  private func access<T>(_ operation: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return operation()
  }
}

private struct ContextCompletionProvider: ChatProvider {
  let onRequest: @Sendable (ChatRequest) -> Void

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    onRequest(request)
    return AsyncThrowingStream { $0.yield(.completed); $0.finish() }
  }
}
