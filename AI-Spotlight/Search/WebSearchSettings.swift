import Combine
import Foundation

protocol WebSearchCredentialStore: Sendable {
  func containsAPIKey() throws -> Bool
  func apiKey() throws -> String?
  func setAPIKey(_ value: String) throws
  func removeAPIKey() throws
}

extension WebSearchCredentialStore {
  func containsAPIKey() throws -> Bool { try apiKey()?.isEmpty == false }
}

struct KeychainSearchCredentialStore: WebSearchCredentialStore {
  private let store = KeychainCredentialStore(service: "com.leow427.AISpotlight.web-search")
  func containsAPIKey() throws -> Bool { try store.containsAPIKey(account: "brave") }
  func apiKey() throws -> String? { try store.apiKey(account: "brave") }
  func setAPIKey(_ value: String) throws { try store.setAPIKey(value, account: "brave") }
  func removeAPIKey() throws { try store.removeAPIKey(account: "brave") }
}

@MainActor
final class WebSearchSettings: ObservableObject {
  static let shared = WebSearchSettings()
  @Published private(set) var hasAPIKey = false
  @Published var automaticallySearch: Bool {
    didSet { defaults.set(automaticallySearch, forKey: Self.automaticSearchKey) }
  }
  var canSearchAutomatically: Bool { automaticallySearch && hasAPIKey }
  private static let automaticSearchKey = "webSearch.automaticallySearch"
  private let defaults: UserDefaults
  private let credentials: any WebSearchCredentialStore

  init(credentials: any WebSearchCredentialStore = KeychainSearchCredentialStore(), defaults: UserDefaults = .standard) {
    self.credentials = credentials
    self.defaults = defaults
    automaticallySearch = defaults.object(forKey: Self.automaticSearchKey) as? Bool ?? true
    hasAPIKey = (try? credentials.containsAPIKey()) ?? false
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
