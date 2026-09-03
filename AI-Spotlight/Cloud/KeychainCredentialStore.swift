import Foundation
import Security

struct KeychainCredentialStore: CloudCredentialStore {
  private let service: String

  init(service: String = "com.leow427.AISpotlight.cloud-api-keys") {
    self.service = service
  }

  func apiKey(for provider: CloudProviderID) throws -> String? {
    var query = baseQuery(for: provider)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess,
          let data = result as? Data,
          let apiKey = String(data: data, encoding: .utf8) else {
      throw KeychainError(status: status)
    }
    return apiKey
  }

  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {
    let data = Data(apiKey.utf8)
    let query = baseQuery(for: provider)
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
    let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }

  private func baseQuery(for provider: CloudProviderID) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: provider.rawValue,
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
