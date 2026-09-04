import Combine
import Foundation

protocol WebSearchCredentialStore: Sendable {
  func apiKey() throws -> String?
  func setAPIKey(_ value: String) throws
  func removeAPIKey() throws
}

struct KeychainSearchCredentialStore: WebSearchCredentialStore {
  private let store = KeychainCredentialStore(service: "com.leow427.AISpotlight.web-search")
  func apiKey() throws -> String? { try store.apiKey(account: "brave") }
  func setAPIKey(_ value: String) throws { try store.setAPIKey(value, account: "brave") }
  func removeAPIKey() throws { try store.removeAPIKey(account: "brave") }
}

@MainActor
final class WebSearchSettings: ObservableObject {
  static let shared = WebSearchSettings()
  @Published private(set) var hasAPIKey = false
  private let credentials: any WebSearchCredentialStore

  init(credentials: any WebSearchCredentialStore = KeychainSearchCredentialStore()) {
    self.credentials = credentials
    hasAPIKey = (try? credentials.apiKey())?.isEmpty == false
  }

  func saveAPIKey(_ value: String) throws {
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { throw WebSearchError.missingAPIKey }
    try credentials.setAPIKey(key)
    hasAPIKey = true
  }

  func removeAPIKey() throws {
    try credentials.removeAPIKey()
    hasAPIKey = false
  }
}
