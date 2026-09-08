import CryptoKit
import Foundation

struct SignedLocalModelCatalog: Codable, Sendable {
  let payload: Data
  let signature: Data
}

struct LocalCatalogTrust: Sendable {
  let url: URL
  let publicKey: Data

  static var configured: Self? {
    guard let address = Bundle.main.object(forInfoDictionaryKey: "LocalModelCatalogURL") as? String,
          let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil,
          let key = Bundle.main.object(forInfoDictionaryKey: "LocalModelCatalogPublicKey") as? String,
          let bytes = Data(base64Encoded: key), bytes.count == 32 else { return nil }
    return Self(url: url, publicKey: bytes)
  }

  func verify(_ data: Data, minimumVersion: Int) throws -> LocalModelManifest {
    guard data.count <= 1_048_576 else { throw LocalModelCatalogError.invalidManifest("catalog size") }
    let envelope = try JSONDecoder().decode(SignedLocalModelCatalog.self, from: data)
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    guard key.isValidSignature(envelope.signature, for: envelope.payload) else {
      throw LocalModelCatalogError.invalidManifest("catalog signature")
    }
    let manifest = try JSONDecoder().decode(LocalModelManifest.self, from: envelope.payload)
    try manifest.validate()
    guard manifest.version >= minimumVersion else {
      throw LocalModelCatalogError.invalidManifest("catalog rollback")
    }
    return manifest
  }
}

actor LocalCatalogUpdater {
  private let cacheURL: URL
  private let checkURL: URL
  private let trust: LocalCatalogTrust?
  private let session: URLSession

  init(directory: URL, trust: LocalCatalogTrust? = .configured, session: URLSession = .shared) {
    cacheURL = directory.appending(path: "signed-model-catalog.json")
    checkURL = directory.appending(path: "catalog-last-check.json")
    self.trust = trust
    self.session = session
  }

  func catalog(now: Date = .now, force: Bool = false) async -> LocalModelManifest {
    var current = LocalModelManifest.bundled
    guard let trust else { return current }
    if let data = try? Data(contentsOf: cacheURL),
       let cached = try? trust.verify(data, minimumVersion: current.version) {
      current = cached
    }
    let lastCheck = (try? Data(contentsOf: checkURL)).flatMap { try? JSONDecoder().decode(Date.self, from: $0) }
    guard force || Self.isDue(lastCheck: lastCheck, now: now) else { return current }
    do {
      // Throttle failed/offline attempts as well; manual refresh can retry sooner.
      try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(now).write(to: checkURL, options: .atomic)
      var request = URLRequest(url: trust.url)
      request.timeoutInterval = 20
      request.cachePolicy = .reloadIgnoringLocalCacheData
      let (bytes, response) = try await session.bytes(for: request)
      guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            response.url?.scheme == "https" else { return current }
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard data.count < 1_048_576 else { return current }
        data.append(byte)
      }
      let updated = try trust.verify(data, minimumVersion: current.version)
      // A version identifies immutable contents, not a mutable release channel.
      guard updated.version > current.version else { return current }
      try data.write(to: cacheURL, options: .atomic)
      return updated
    } catch {
      return current
    }
  }

  static func isDue(lastCheck: Date?, now: Date) -> Bool {
    guard let lastCheck else { return true }
    return lastCheck > now || now.timeIntervalSince(lastCheck) >= 30 * 86_400
  }
}
