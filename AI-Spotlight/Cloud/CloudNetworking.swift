import Foundation

final class URLSessionCloudTransport: CloudNetworkTransport, @unchecked Sendable {
  static let shared = URLSessionCloudTransport(session: .shared)

  private let session: URLSession

  init(session: URLSession) {
    self.session = session
  }

  func data(for request: URLRequest) async throws -> CloudDataResponse {
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw CloudProviderError.invalidResponse
    }
    return CloudDataResponse(data: data, statusCode: httpResponse.statusCode)
  }

  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let (bytes, response) = try await session.bytes(for: request)
          guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudProviderError.invalidResponse
          }
          continuation.yield(.response(statusCode: httpResponse.statusCode))

          var buffer = [UInt8]()
          buffer.reserveCapacity(4_096)
          for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count == 4_096 {
              continuation.yield(.data(Data(buffer)))
              buffer.removeAll(keepingCapacity: true)
            }
          }
          if !buffer.isEmpty {
            continuation.yield(.data(Data(buffer)))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: normalizedCloudError(error))
        }
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }
}
