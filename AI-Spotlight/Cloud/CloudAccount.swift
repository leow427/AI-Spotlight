import CryptoKit
import Foundation
import Security

struct CloudBackendConfiguration: Equatable, Sendable {
  static let live = CloudBackendConfiguration(
    rawURL: ProcessInfo.processInfo.environment["AI_SPOTLIGHT_BACKEND_URL"]
      ?? Bundle.main.object(forInfoDictionaryKey: "AISpotlightBackendURL") as? String
  )

  let baseURL: URL?

  init(rawURL: String?) {
    let value = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !value.isEmpty,
          !value.contains("$("),
          let url = URL(string: value),
          url.scheme?.lowercased() == "https",
          url.host != nil else {
      baseURL = nil
      return
    }
    baseURL = url
  }

  init(baseURL: URL?) {
    self.baseURL = baseURL
  }

  var isConfigured: Bool { baseURL != nil }
}

struct CloudAccountSession: Codable, Equatable, Sendable {
  let accessToken: String
  let expiresAt: Date

  func isValid(now: Date = .now) -> Bool {
    !accessToken.isEmpty && expiresAt.timeIntervalSince(now) > 30
  }
}

protocol CloudAccountSessionStoring: Sendable {
  func session() throws -> CloudAccountSession?
  func setSession(_ session: CloudAccountSession) throws
  func removeSession() throws
}

struct KeychainCloudAccountSessionStore: CloudAccountSessionStoring {
  private let service = "com.leow427.AISpotlight.cloud-account"
  private let account = "backend-session"

  func session() throws -> CloudAccountSession? {
    var query = baseQuery
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw CloudAccountKeychainError(status: status)
    }
    guard let value = try? JSONDecoder().decode(CloudAccountSession.self, from: data) else {
      try removeSession()
      return nil
    }
    guard value.isValid() else {
      try removeSession()
      return nil
    }
    return value
  }

  func setSession(_ session: CloudAccountSession) throws {
    let data = try JSONEncoder().encode(session)
    let attributes: [CFString: Any] = [kSecValueData: data]
    let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw CloudAccountKeychainError(status: updateStatus)
    }

    var query = baseQuery
    query[kSecValueData] = data
    query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(query as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw CloudAccountKeychainError(status: addStatus)
    }
  }

  func removeSession() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CloudAccountKeychainError(status: status)
    }
  }

  private var baseQuery: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
  }
}

private struct CloudAccountKeychainError: LocalizedError {
  let status: OSStatus

  var errorDescription: String? {
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
    return "Unable to update the cloud account session in Keychain: \(detail)."
  }
}

enum CloudAccessKind: Equatable, Sendable {
  case directAPIKey
  case backendSession
}

struct CloudAccess: Equatable, Sendable {
  let kind: CloudAccessKind
  let credential: String
  let backendURL: URL?

  var usesBackend: Bool { kind == .backendSession }

  func endpoint(
    provider: CloudProviderID,
    operation: String,
    directURL: URL
  ) -> URL {
    guard let backendURL else { return directURL }
    return backendURL
      .appending(path: "v1")
      .appending(path: "providers")
      .appending(path: provider.rawValue)
      .appending(path: operation)
  }

  func cacheKey(for provider: CloudProviderID) -> String {
    guard let backendURL else { return provider.rawValue }
    return "backend:\(backendURL.absoluteString):\(provider.rawValue)"
  }
}

protocol CloudAccessResolving: Sendable {
  func access(for provider: CloudProviderID) throws -> CloudAccess?
}

struct DirectCloudAccessResolver: CloudAccessResolving {
  let credentialStore: any CloudCredentialStore

  func access(for provider: CloudProviderID) throws -> CloudAccess? {
    guard let key = try credentialStore.apiKey(for: provider), !key.isEmpty else { return nil }
    return CloudAccess(kind: .directAPIKey, credential: key, backendURL: nil)
  }
}

struct PreferredCloudAccessResolver: CloudAccessResolving {
  let credentialStore: any CloudCredentialStore
  let sessionStore: any CloudAccountSessionStoring
  let backend: CloudBackendConfiguration

  func access(for provider: CloudProviderID) throws -> CloudAccess? {
    if let baseURL = backend.baseURL,
       let session = try sessionStore.session(),
       session.isValid() {
      return CloudAccess(
        kind: .backendSession,
        credential: session.accessToken,
        backendURL: baseURL
      )
    }
    return try DirectCloudAccessResolver(credentialStore: credentialStore).access(for: provider)
  }
}

protocol CloudAccountAuthenticating: Sendable {
  func signIn(identityToken: Data, nonce: String) async throws -> CloudAccountSession
}

struct URLSessionCloudAccountClient: CloudAccountAuthenticating {
  private let backend: CloudBackendConfiguration
  private let transport: any CloudNetworkTransport
  private let now: @Sendable () -> Date

  init(
    backend: CloudBackendConfiguration,
    transport: any CloudNetworkTransport,
    now: @escaping @Sendable () -> Date = { .now }
  ) {
    self.backend = backend
    self.transport = transport
    self.now = now
  }

  func signIn(identityToken: Data, nonce: String) async throws -> CloudAccountSession {
    guard let baseURL = backend.baseURL else {
      throw CloudProviderError.backendNotConfigured
    }
    guard let identityToken = String(data: identityToken, encoding: .utf8),
          !identityToken.isEmpty,
          !nonce.isEmpty else {
      throw CloudProviderError.invalidAppleCredential
    }

    struct RequestBody: Encodable {
      let identityToken: String
      let nonce: String

      enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case nonce
      }
    }
    struct ResponseBody: Decodable {
      let accessToken: String
      let expiresIn: TimeInterval

      enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
      }
    }

    var request = URLRequest(
      url: baseURL.appending(path: "v1").appending(path: "auth").appending(path: "apple")
    )
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      RequestBody(identityToken: identityToken, nonce: nonce)
    )

    let response: CloudDataResponse
    do {
      response = try await transport.data(for: request)
    } catch {
      throw normalizedCloudError(error)
    }
    guard (200...299).contains(response.statusCode) else {
      if response.statusCode == 401 || response.statusCode == 403 {
        throw CloudProviderError.accountAuthenticationFailed
      }
      throw CloudProviderError.requestFailed(
        statusCode: response.statusCode,
        message: cloudServiceErrorMessage(in: response.data)
      )
    }
    guard let payload = try? JSONDecoder().decode(ResponseBody.self, from: response.data),
          !payload.accessToken.isEmpty,
          payload.expiresIn > 0 else {
      throw CloudProviderError.invalidResponse
    }
    return CloudAccountSession(
      accessToken: payload.accessToken,
      expiresAt: now().addingTimeInterval(payload.expiresIn)
    )
  }
}

enum AppleSignInNonce {
  static func make() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "")
      + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

  static func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
