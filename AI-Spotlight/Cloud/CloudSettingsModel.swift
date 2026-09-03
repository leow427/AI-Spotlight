import Combine
import Foundation

struct CloudPreferencesStore: @unchecked Sendable {
  private enum Key {
    static let preferredProvider = "aiSpotlight.cloud.preferredProvider"
    static func preferredModel(_ provider: CloudProviderID) -> String {
      "aiSpotlight.cloud.preferredModel.\(provider.rawValue)"
    }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func preferredProvider() -> CloudProviderID {
    defaults.string(forKey: Key.preferredProvider)
      .flatMap(CloudProviderID.init(rawValue:)) ?? .openAI
  }

  func setPreferredProvider(_ provider: CloudProviderID) {
    defaults.set(provider.rawValue, forKey: Key.preferredProvider)
  }

  func preferredModel(for provider: CloudProviderID) -> String {
    defaults.string(forKey: Key.preferredModel(provider)) ?? ""
  }

  func setPreferredModel(_ modelID: String, for provider: CloudProviderID) {
    defaults.set(modelID, forKey: Key.preferredModel(provider))
  }
}

@MainActor
final class CloudSettingsModel: ObservableObject {
  enum ConnectionState: Equatable {
    case idle
    case testing
    case connected(Int)
    case failed(String)
  }

  static let shared: CloudSettingsModel = {
    let credentialStore = KeychainCredentialStore()
    return CloudSettingsModel(
      credentialStore: credentialStore,
      catalog: CloudModelCatalog(
        credentialStore: credentialStore,
        transport: URLSessionCloudTransport.shared
      )
    )
  }()

  @Published var preferredProvider: CloudProviderID {
    didSet {
      guard preferredProvider != oldValue else { return }
      preferences.setPreferredProvider(preferredProvider)
      preferredModelID = preferences.preferredModel(for: preferredProvider)
      models = []
      discoveryError = nil
      Task { await loadCachedModels() }
    }
  }

  @Published var preferredModelID: String {
    didSet {
      preferences.setPreferredModel(
        preferredModelID.trimmingCharacters(in: .whitespacesAndNewlines),
        for: preferredProvider
      )
    }
  }

  @Published private(set) var models: [CloudModel] = []
  @Published private(set) var discoveryError: String?
  @Published private(set) var isDiscovering = false
  @Published private(set) var credentialRevision = 0
  @Published private(set) var connectionStates: [CloudProviderID: ConnectionState] = [:]

  private let credentialStore: any CloudCredentialStore
  private let catalog: CloudModelCatalog
  private let preferences: CloudPreferencesStore

  init(
    credentialStore: any CloudCredentialStore,
    catalog: CloudModelCatalog,
    preferences: CloudPreferencesStore = CloudPreferencesStore()
  ) {
    self.credentialStore = credentialStore
    self.catalog = catalog
    self.preferences = preferences
    let provider = preferences.preferredProvider()
    preferredProvider = provider
    preferredModelID = preferences.preferredModel(for: provider)
  }

  var isConfigured: Bool {
    hasAPIKey(for: preferredProvider)
      && !preferredModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func hasAPIKey(for provider: CloudProviderID) -> Bool {
    guard let apiKey = try? credentialStore.apiKey(for: provider) else { return false }
    return !apiKey.isEmpty
  }

  func saveAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {
    let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedAPIKey.isEmpty else { return }
    try credentialStore.setAPIKey(trimmedAPIKey, for: provider)
    credentialRevision += 1
    connectionStates[provider] = .idle
  }

  func removeAPIKey(for provider: CloudProviderID) throws {
    try credentialStore.removeAPIKey(for: provider)
    credentialRevision += 1
    connectionStates[provider] = .idle
  }

  func loadCachedModels() async {
    if let cached = await catalog.cachedModels(for: preferredProvider) {
      models = cached
      selectFirstModelIfNeeded()
    }
  }

  func discoverModels(forceRefresh: Bool = false) async {
    isDiscovering = true
    discoveryError = nil
    defer { isDiscovering = false }
    do {
      models = try await catalog.models(
        for: preferredProvider,
        forceRefresh: forceRefresh
      )
      selectFirstModelIfNeeded()
    } catch {
      models = []
      discoveryError = error.localizedDescription
    }
  }

  func testConnection(to provider: CloudProviderID) async {
    connectionStates[provider] = .testing
    do {
      let discovered = try await catalog.models(for: provider, forceRefresh: true)
      connectionStates[provider] = .connected(discovered.count)
      if provider == preferredProvider {
        models = discovered
        discoveryError = nil
        selectFirstModelIfNeeded()
      }
    } catch {
      connectionStates[provider] = .failed(error.localizedDescription)
    }
  }

  func connectionState(for provider: CloudProviderID) -> ConnectionState {
    connectionStates[provider] ?? .idle
  }

  private func selectFirstModelIfNeeded() {
    guard preferredModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let firstModel = models.first else { return }
    preferredModelID = firstModel.id
  }
}
