import Foundation

actor CloudModelCatalog {
  static let cacheLifetime: TimeInterval = 24 * 60 * 60

  private struct CacheEntry: Codable {
    let fetchedAt: Date
    let models: [CloudModel]
  }

  private struct CacheArchive: Codable {
    var providers: [String: CacheEntry] = [:]
  }

  private let credentialStore: any CloudCredentialStore
  private let transport: any CloudNetworkTransport
  private let cacheURL: URL
  private let openAIModelsURL: URL
  private let anthropicModelsURL: URL

  init(
    credentialStore: any CloudCredentialStore,
    transport: any CloudNetworkTransport,
    cacheDirectory: URL? = nil,
    openAIModelsURL: URL = URL(string: "https://api.openai.com/v1/models")!,
    anthropicModelsURL: URL = URL(string: "https://api.anthropic.com/v1/models?limit=1000")!
  ) {
    self.credentialStore = credentialStore
    self.transport = transport
    let directory = cacheDirectory ?? FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "AI Spotlight", directoryHint: .isDirectory)
    cacheURL = directory.appending(path: "cloud-models.json")
    self.openAIModelsURL = openAIModelsURL
    self.anthropicModelsURL = anthropicModelsURL
  }

  func cachedModels(
    for provider: CloudProviderID,
    now: Date = .now
  ) -> [CloudModel]? {
    guard let entry = loadArchive().providers[provider.rawValue],
          now.timeIntervalSince(entry.fetchedAt) < Self.cacheLifetime else {
      return nil
    }
    return entry.models
  }

  func models(
    for provider: CloudProviderID,
    forceRefresh: Bool = false,
    now: Date = .now
  ) async throws -> [CloudModel] {
    var archive = loadArchive()
    if !forceRefresh,
       let entry = archive.providers[provider.rawValue],
       now.timeIntervalSince(entry.fetchedAt) < Self.cacheLifetime {
      return entry.models
    }

    guard let apiKey = try credentialStore.apiKey(for: provider), !apiKey.isEmpty else {
      throw CloudProviderError.missingAPIKey(provider)
    }
    let request = makeRequest(provider: provider, apiKey: apiKey)
    let response: CloudDataResponse
    do {
      response = try await transport.data(for: request)
    } catch {
      throw normalizedCloudError(error)
    }
    guard (200...299).contains(response.statusCode) else {
      throw cloudHTTPError(
        provider: provider,
        statusCode: response.statusCode,
        data: response.data
      )
    }

    let discoveredModels = try decodeModels(response.data, provider: provider)
    guard !discoveredModels.isEmpty else {
      throw CloudProviderError.invalidResponse
    }
    archive.providers[provider.rawValue] = CacheEntry(
      fetchedAt: now,
      models: discoveredModels
    )
    try saveArchive(archive)
    return discoveredModels
  }

  private func makeRequest(provider: CloudProviderID, apiKey: String) -> URLRequest {
    let url = provider == .openAI ? openAIModelsURL : anthropicModelsURL
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    switch provider {
    case .openAI:
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    case .anthropic:
      request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }
    return request
  }

  private func decodeModels(
    _ data: Data,
    provider: CloudProviderID
  ) throws -> [CloudModel] {
    switch provider {
    case .openAI:
      struct Response: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
      }
      guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
        throw CloudProviderError.invalidResponse
      }
      return response.data
        .map { CloudModel(id: $0.id, displayName: $0.id, provider: provider) }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    case .anthropic:
      struct Response: Decodable {
        struct Model: Decodable {
          let id: String
          let displayName: String

          enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
          }
        }
        let data: [Model]
      }
      guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
        throw CloudProviderError.invalidResponse
      }
      return response.data.map {
        CloudModel(id: $0.id, displayName: $0.displayName, provider: provider)
      }
    }
  }

  private func loadArchive() -> CacheArchive {
    guard let data = try? Data(contentsOf: cacheURL),
          let archive = try? decoder.decode(CacheArchive.self, from: data) else {
      return CacheArchive()
    }
    return archive
  }

  private func saveArchive(_ archive: CacheArchive) throws {
    try FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try encoder.encode(archive).write(to: cacheURL, options: .atomic)
  }

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
