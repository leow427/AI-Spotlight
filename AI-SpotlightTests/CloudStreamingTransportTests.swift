import Combine
import Foundation
import XCTest
@testable import PrimaryAgent

@MainActor
final class CloudStreamingTransportTests: XCTestCase {
  func testSmallCompleteEventArrivesThroughURLSessionBeforeEOF() async throws {
    let fixture = StreamingSessionFixture()
    defer { fixture.close() }
    let received = expectation(description: "Complete SSE event received while source is open")
    let payload = Data("event: message\ndata: hello\n\n".utf8)
    XCTAssertLessThan(payload.count, 4_096)
    var networkEvents: [CloudNetworkEvent] = []
    var parsedEvents: [ServerSentEvent] = []
    let consumer = Task {
      var parser = ServerSentEventParser()
      for try await event in fixture.transport.stream(for: fixture.request) {
        networkEvents.append(event)
        if case .data(let data) = event {
          let events = parser.append(data)
          parsedEvents += events
          if !events.isEmpty { received.fulfill() }
        }
      }
    }
    defer { consumer.cancel() }
    await fulfillment(of: [fixture.source.started], timeout: 2)
    fixture.source.respond()
    fixture.source.send(payload)
    await fulfillment(of: [received], timeout: 2)

    XCTAssertFalse(fixture.source.hasEnded)
    XCTAssertEqual(networkEvents.first, .response(statusCode: 200))
    XCTAssertEqual(parsedEvents, [ServerSentEvent(event: "message", data: "hello")])
    fixture.source.finish()
    try await consumer.value
    XCTAssertEqual(networkEvents.compactMap { event -> Data? in
      if case .data(let data) = event { return data }
      return nil
    }.reduce(Data(), +), payload)
  }

  func testDirectProvidersDeliverFragmentedSmallEventsIncrementally() async throws {
    for provider in [CloudProviderID.openAI, .anthropic] {
      let fixture = StreamingSessionFixture()
      defer { fixture.close() }
      let texts = ["Hello", " café 🦊 漢字", " last"]
      let received = texts.map { text in expectation(description: "Received \(provider): \(text)") }
      var events: [ChatEvent] = []
      let consumer = Task {
        for try await event in fixture.client(provider).stream(request(provider)) {
          events.append(event)
          if case .token(let text) = event, let index = texts.firstIndex(of: text) {
            received[index].fulfill()
          }
        }
      }
      defer { consumer.cancel() }
      await fulfillment(of: [fixture.source.started], timeout: 2)
      fixture.source.respond()
      for (index, text) in texts.enumerated() {
        // One-byte source writes split every Unicode scalar and CRLF delimiter.
        fixture.source.send(token(text, provider: provider, newline: "\r\n"), bytewise: true)
        await fulfillment(of: [received[index]], timeout: 2)
        XCTAssertFalse(fixture.source.hasEnded)
        XCTAssertEqual(events, texts.prefix(index + 1).map(ChatEvent.token))
      }
      fixture.source.send(completion(provider))
      fixture.source.finish()
      try await consumer.value
      XCTAssertEqual(events, texts.map(ChatEvent.token) + [.completed])
    }
  }

  func testLongLineSplitInsideUTF8AtTransportLimitIsLossless() async throws {
    let fixture = StreamingSessionFixture()
    defer { fixture.close() }
    // "data: " is six bytes, so the first emoji straddles the 4,096-byte flush.
    let text = String(repeating: "a", count: 4_089) + "🦊é" + String(repeating: "z", count: 4_096)
    let received = expectation(description: "Large event assembled before EOF")
    var chunks: [Data] = []
    var events: [ServerSentEvent] = []
    let consumer = Task {
      var parser = ServerSentEventParser()
      for try await event in fixture.transport.stream(for: fixture.request) {
        if case .data(let data) = event {
          chunks.append(data)
          let parsed = parser.append(data)
          events += parsed
          if !parsed.isEmpty { received.fulfill() }
        }
      }
    }
    defer { consumer.cancel() }
    await fulfillment(of: [fixture.source.started], timeout: 2)
    fixture.source.respond()
    let payload = Data("data: \(text)\n\n".utf8)
    fixture.source.send(payload)
    await fulfillment(of: [received], timeout: 2)
    XCTAssertFalse(fixture.source.hasEnded)
    XCTAssertEqual(events, [ServerSentEvent(event: nil, data: text)])
    XCTAssertTrue(chunks.allSatisfy { $0.count <= 4_096 })
    XCTAssertEqual(chunks.first?.last, 0xF0)
    XCTAssertEqual(chunks.reduce(Data(), +), payload)
    fixture.source.finish()
    try await consumer.value
  }

  func testParserWaitsForSplitUnicodeAndBlankLineDelimiter() {
    var parser = ServerSentEventParser()
    let prefix = Data("event: message\r\ndata: café ".utf8)
    let emoji = Array("🦊".utf8)
    XCTAssertTrue(parser.append(prefix + Data(emoji.prefix(2))).isEmpty)
    XCTAssertTrue(parser.append(Data(emoji.suffix(2)) + Data("\r".utf8)).isEmpty)
    XCTAssertTrue(parser.append(Data("\n\r".utf8)).isEmpty)
    XCTAssertEqual(parser.append(Data("\n".utf8)), [
      ServerSentEvent(event: "message", data: "café 🦊"),
    ])
    XCTAssertTrue(parser.finish().isEmpty)
  }

  func testEOFForwardsTrailingBytesForErrorBodies() async throws {
    let fixture = StreamingSessionFixture()
    defer { fixture.close() }
    let body = Data("{\"error\":{\"message\":\"No capacity 🦊\"}}".utf8)
    let consumer = Task {
      var events: [CloudNetworkEvent] = []
      for try await event in fixture.transport.stream(for: fixture.request) { events.append(event) }
      return events
    }
    defer { consumer.cancel() }
    await fulfillment(of: [fixture.source.started], timeout: 2)
    fixture.source.respond(statusCode: 503)
    fixture.source.send(body, bytewise: true)
    fixture.source.finish()
    let events = try await consumer.value
    XCTAssertEqual(events, [.response(statusCode: 503), .data(body)])
  }

  func testDirectProvidersRetainPartialOutputWhenURLSessionFailsOrEndsEarly() async throws {
    for provider in [CloudProviderID.openAI, .anthropic] {
      for networkFailure in [false, true] {
        let fixture = StreamingSessionFixture()
        defer { fixture.close() }
        let received = expectation(description: "Partial output before source failure")
        var events: [ChatEvent] = []
        let consumer = Task { () -> CloudProviderError? in
          do {
            for try await event in fixture.client(provider).stream(request(provider)) {
              events.append(event)
              if event == .token("Partial 🦊") { received.fulfill() }
            }
            XCTFail("Expected stream failure")
            return nil
          } catch { return error as? CloudProviderError }
        }
        defer { consumer.cancel() }
        await fulfillment(of: [fixture.source.started], timeout: 2)
        fixture.source.respond()
        fixture.source.send(token("Partial 🦊", provider: provider))
        await fulfillment(of: [received], timeout: 2)
        // An incomplete next event must never turn into a token on failure.
        if networkFailure { fixture.source.send(Data("data: {\"type\":".utf8)) }
        fixture.source.finish(error: networkFailure ? URLError(.networkConnectionLost) : nil)
        let error = await consumer.value
        XCTAssertEqual(error, networkFailure ? .offline : .streamEndedUnexpectedly)
        XCTAssertEqual(events, [.token("Partial 🦊")])
      }
    }
  }

  func testCancellingTransportWhileWaitingForHeadersOrBytesStopsURLSession() async throws {
    for sendHeaders in [false, true] {
      let fixture = StreamingSessionFixture()
      defer { fixture.close() }
      let headers = sendHeaders ? expectation(description: "Headers consumed") : nil
      let consumer = Task {
        for try await event in fixture.transport.stream(for: fixture.request) {
          if case .response = event { headers?.fulfill() }
        }
      }
      await fulfillment(of: [fixture.source.started], timeout: 2)
      if let headers {
        fixture.source.respond()
        await fulfillment(of: [headers], timeout: 2)
      }
      consumer.cancel()
      _ = await consumer.result
      await fulfillment(of: [fixture.source.stopped], timeout: 2)
      XCTAssertFalse(fixture.source.hasEnded, "The consumer must cancel an open source")
    }
  }

  func testStoppingDirectProvidersCancelsURLSessionAndPreservesSavedPartialOutput() async throws {
    try await verifyViewModelEnding(stop: true)
  }

  func testURLSessionFailurePreservesPartialOutputInChatAndArchive() async throws {
    try await verifyViewModelEnding(stop: false)
  }

  private func verifyViewModelEnding(stop: Bool) async throws {
    for provider in [CloudProviderID.openAI, .anthropic] {
      let fixture = StreamingSessionFixture()
      defer { fixture.close() }
      let root = FileManager.default.temporaryDirectory.appending(path: "CloudStreamingTests-\(UUID())")
      defer { try? FileManager.default.removeItem(at: root) }
      let store = ChatSessionStore(applicationSupportDirectory: root)
      let viewModel = LocalChatViewModel(
        engine: LlamaCPPModelEngine(installationStore: LocalModelInstallationStore(modelsDirectory: root.appending(path: "models"))),
        cloudProviders: CloudProviderRegistry(credentialStore: StreamingTestCredentials(), transport: fixture.transport),
        sessionStore: store
      )
      viewModel.submitCloud("Question", provider: provider, modelID: "fixture")
      defer { viewModel.stopStreaming() }
      let received = expectation(description: "Partial output visible in chat")
      let failed = stop ? nil : expectation(description: "Network failure visible in chat")
      let observation = viewModel.$state.sink { state in
        if state == .streaming { received.fulfill() }
        if case .failed = state { failed?.fulfill() }
      }
      defer { observation.cancel() }
      await fulfillment(of: [fixture.source.started], timeout: 2)
      fixture.source.respond()
      fixture.source.send(token("Saved partial 🦊", provider: provider))
      await fulfillment(of: [received], timeout: 2)
      XCTAssertTrue(viewModel.isBusy)
      XCTAssertEqual(viewModel.messages.last?.content, "Saved partial 🦊")
      if stop {
        await viewModel.stopStreaming()?.value
        await fulfillment(of: [fixture.source.stopped], timeout: 2)
        XCTAssertFalse(fixture.source.hasEnded)
        XCTAssertEqual(viewModel.state, .idle)
      } else {
        fixture.source.finish(error: URLError(.networkConnectionLost))
        await fulfillment(of: [try XCTUnwrap(failed)], timeout: 2)
        XCTAssertEqual(viewModel.state, .failed(CloudProviderError.offline.localizedDescription))
      }
      XCTAssertFalse(viewModel.isBusy)
      XCTAssertNil(viewModel.activeRequest)
      XCTAssertEqual(viewModel.messages.map(\.content), ["Question", "Saved partial 🦊"])
      XCTAssertEqual(store.load().first?.messages.map(\.content), ["Question", "Saved partial 🦊"])
    }
  }

  private func request(_ provider: CloudProviderID) -> ChatRequest {
    ChatRequest(sessionID: UUID(), messages: [ChatMessage(role: .user, content: "Question")], route: Route(
      mode: .cloud, providerID: provider.rawValue, modelID: "fixture", usesNetwork: true
    ))
  }

  private func token(_ text: String, provider: CloudProviderID, newline: String = "\n") -> Data {
    let payload: [String: Any] = provider == .openAI
      ? ["type": "response.output_text.delta", "delta": text]
      : ["type": "content_block_delta", "delta": ["type": "text_delta", "text": text]]
    let json = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    return Data("data: \(json)\(newline)\(newline)".utf8)
  }

  private func completion(_ provider: CloudProviderID) -> Data {
    let type = provider == .openAI ? "response.completed" : "message_stop"
    return Data("data: {\"type\":\"\(type)\"}\n\n".utf8)
  }
}

private struct StreamingTestCredentials: CloudCredentialStore {
  func apiKey(for provider: CloudProviderID) throws -> String? { "fixture-key" }
  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {}
  func removeAPIKey(for provider: CloudProviderID) throws {}
}

private final class StreamingSessionFixture {
  let source = ControlledStreamingSource()
  let session: URLSession
  let transport: URLSessionCloudTransport
  let request = URLRequest(url: URL(string: "https://streaming.invalid/events")!)
  private let id = UUID().uuidString

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ControlledStreamingURLProtocol.self]
    configuration.httpAdditionalHeaders = [ControlledStreamingURLProtocol.sourceHeader: id]
    configuration.urlCache = nil
    session = URLSession(configuration: configuration)
    transport = URLSessionCloudTransport(session: session)
    ControlledStreamingURLProtocol.sources.set(source, for: id)
  }

  func client(_ provider: CloudProviderID) -> any ChatProvider {
    CloudProviderRegistry(credentialStore: StreamingTestCredentials(), transport: transport).provider(for: provider)
  }

  func close() {
    session.invalidateAndCancel()
    ControlledStreamingURLProtocol.sources.set(nil, for: id)
  }
}

// Only the session boundary is controlled: the real AsyncBytes transport,
// buffering, parser, provider clients, and view model execute unchanged.
private final class ControlledStreamingURLProtocol: URLProtocol, @unchecked Sendable {
  static let sourceHeader = "X-Streaming-Test-Source"
  static let sources = StreamingSourceRegistry()
  private var source: ControlledStreamingSource?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let id = request.value(forHTTPHeaderField: Self.sourceHeader),
          let source = Self.sources.get(id) else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    self.source = source
    source.start(self)
  }

  override func stopLoading() { source?.stop() }
}

private final class StreamingSourceRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var sources: [String: ControlledStreamingSource] = [:]
  func set(_ source: ControlledStreamingSource?, for id: String) { lock.withLock { sources[id] = source } }
  func get(_ id: String) -> ControlledStreamingSource? { lock.withLock { sources[id] } }
}

private final class ControlledStreamingSource: @unchecked Sendable {
  let started = XCTestExpectation(description: "URLSession source started")
  let stopped = XCTestExpectation(description: "URLSession stopped the open source")
  private let queue = DispatchQueue(label: "CloudStreamingTests.source")
  private var loadingProtocol: ControlledStreamingURLProtocol?
  private var ended = false
  var hasEnded: Bool { queue.sync { ended } }

  func start(_ loadingProtocol: ControlledStreamingURLProtocol) {
    queue.async {
      self.loadingProtocol = loadingProtocol
      self.started.fulfill()
    }
  }

  func respond(statusCode: Int = 200) {
    queue.async {
      guard let loading = self.loadingProtocol else { return }
      let response = HTTPURLResponse(url: loading.request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
      loading.client?.urlProtocol(loading, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
  }

  func send(_ data: Data, bytewise: Bool = false) {
    queue.async {
      guard let loading = self.loadingProtocol else { return }
      if bytewise {
        for byte in data { loading.client?.urlProtocol(loading, didLoad: Data([byte])) }
      } else {
        loading.client?.urlProtocol(loading, didLoad: data)
      }
    }
  }

  func finish(error: Error? = nil) {
    queue.async {
      guard let loading = self.loadingProtocol else { return }
      self.ended = true
      if let error { loading.client?.urlProtocol(loading, didFailWithError: error) }
      else { loading.client?.urlProtocolDidFinishLoading(loading) }
      self.loadingProtocol = nil
    }
  }

  func stop() {
    queue.async {
      self.loadingProtocol = nil
      self.stopped.fulfill()
    }
  }
}
