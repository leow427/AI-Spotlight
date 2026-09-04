import Foundation
import LocalAuthentication
import Security

struct KeychainCredentialStore: CloudCredentialStore {
  typealias CopyMatching = @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
  private let service: String
  private let copyMatching: CopyMatching

  init(
    service: String = "com.leow427.AISpotlight.cloud-api-keys",
    copyMatching: @escaping CopyMatching = { SecItemCopyMatching($0, $1) }
  ) {
    self.service = service
    self.copyMatching = copyMatching
  }

  func containsAPIKey(for provider: CloudProviderID) throws -> Bool {
    try containsAPIKey(account: provider.rawValue)
  }

  func containsAPIKey(account: String) throws -> Bool {
    // Routing and SwiftUI rendering only need existence. Reading password data here
    // can wait on a Keychain authorization dialog and freeze the panel's UI thread.
    var query = baseQuery(account: account)
    query[kSecMatchLimit] = kSecMatchLimitOne
    query[kSecReturnAttributes] = true
    let authentication = LAContext()
    authentication.interactionNotAllowed = true
    query[kSecUseAuthenticationContext] = authentication
    let status = copyMatching(query as CFDictionary, nil)
    if status == errSecItemNotFound || status == errSecInteractionNotAllowed { return false }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    return true
  }

  func apiKey(for provider: CloudProviderID) throws -> String? {
    try apiKey(account: provider.rawValue)
  }

  func apiKey(account: String) throws -> String? {
    var query = baseQuery(account: account)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = copyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess,
          let data = result as? Data,
          let apiKey = String(data: data, encoding: .utf8) else {
      throw KeychainError(status: status)
    }
    return apiKey
  }

  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {
    try setAPIKey(apiKey, account: provider.rawValue)
  }

  func setAPIKey(_ apiKey: String, account: String) throws {
    let data = Data(apiKey.utf8)
    let query = baseQuery(account: account)
    let status = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData: data] as CFDictionary
    )
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }

    var newItem = query
    newItem[kSecValueData] = data
    newItem[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
    let addStatus = SecItemAdd(newItem as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainError(status: addStatus)
    }
  }

  func removeAPIKey(for provider: CloudProviderID) throws {
    try removeAPIKey(account: provider.rawValue)
  }

  func removeAPIKey(account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }

  private func baseQuery(account: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
  }
}

private struct KeychainError: LocalizedError {
  let status: OSStatus

  var errorDescription: String? {
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
    return "Unable to update the Keychain: \(detail)."
  }
}
