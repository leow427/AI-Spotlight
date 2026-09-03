import Foundation
import LlamaBridge

actor LlamaCPPModelEngine: LocalModelEngine {
  private let installationStore: LocalModelInstallationStore
  private let contextSize: Int32
  private var engineHandle: AISLlamaEngineHandle?
  private var loadedModelURL: URL?

  init(
    installationStore: LocalModelInstallationStore = LocalModelInstallationStore(),
    contextSize: Int32 = 4_096
  ) {
    self.installationStore = installationStore
    self.contextSize = contextSize
  }

  func install(_ model: LocalModel) async throws {
    releaseEngine()
    _ = try installationStore.install(model)
  }

  func installedModel() async -> LocalModel? {
    installationStore.installedModel()
  }

  nonisolated func stream(
    _ request: LocalModelRequest
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        await self.generate(request, continuation: continuation)
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  func unload() async {
    releaseEngine()
  }

  private func generate(
    _ request: LocalModelRequest,
    continuation: AsyncThrowingStream<String, Error>.Continuation
  ) {
    do {
      try Task.checkCancellation()
      let handle = try loadEngineIfNeeded()
      try beginCompletion(request, with: handle)

      var pendingBytes = Data()
      var tokenBuffer = [UInt8](repeating: 0, count: 4_096)
      while true {
        try Task.checkCancellation()
        var byteCount: Int32 = 0
        let result = tokenBuffer.withUnsafeMutableBufferPointer { buffer in
          AISLlamaEngineNextToken(
            handle,
            buffer.baseAddress,
            Int32(buffer.count),
            &byteCount
          )
        }

        if result < 0 {
          throw bridgeError()
        }
        if result == 0 {
          if !pendingBytes.isEmpty {
            continuation.yield(String(decoding: pendingBytes, as: UTF8.self))
          }
          continuation.finish()
          return
        }

        pendingBytes.append(contentsOf: tokenBuffer.prefix(Int(byteCount)))
        if let fragment = String(data: pendingBytes, encoding: .utf8) {
          pendingBytes.removeAll(keepingCapacity: true)
          if !fragment.isEmpty {
            continuation.yield(fragment)
          }
        }
      }
    } catch {
      continuation.finish(throwing: error)
    }
  }

  private func loadEngineIfNeeded() throws -> AISLlamaEngineHandle {
    guard let installedModel = installationStore.installedModel() else {
      throw LocalInferenceError.noModelInstalled
    }
    if let engineHandle, loadedModelURL == installedModel.fileURL {
      return engineHandle
    }

    releaseEngine()
    let newHandle = installedModel.fileURL.path.withCString { path in
      AISLlamaEngineCreate(path, contextSize)
    }
    guard let newHandle else {
      throw bridgeError()
    }

    engineHandle = newHandle
    loadedModelURL = installedModel.fileURL
    return newHandle
  }

  private func beginCompletion(
    _ request: LocalModelRequest,
    with handle: AISLlamaEngineHandle
  ) throws {
    let didBegin = request.prompt.withCString { prompt in
      AISLlamaEngineBeginCompletion(
        handle,
        prompt,
        Int32(clamping: request.maximumTokenCount),
        request.temperature
      )
    }
    guard didBegin else {
      throw bridgeError()
    }
  }

  private func bridgeError() -> LocalInferenceError {
    guard let errorMessage = AISLlamaBridgeLastError() else {
      return .bridgeFailure("llama.cpp encountered an unknown error.")
    }
    return .bridgeFailure(String(cString: errorMessage))
  }

  private func releaseEngine() {
    if let engineHandle {
      AISLlamaEngineDestroy(engineHandle)
    }
    engineHandle = nil
    loadedModelURL = nil
  }
}
