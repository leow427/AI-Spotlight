import Combine
import Foundation

enum ModelDiscoveryScope: String, CaseIterable, Identifiable, Sendable {
  case all = "All", vision = "Vision", audio = "Audio"
  var id: Self { self }
}

struct HuggingFaceTask: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let scope: ModelDiscoveryScope

  // Hugging Face's public task taxonomy. Use tags, rather than only the primary
  // pipeline, so secondary modalities on conversational models are discoverable.
  static let all: [Self] = [
    Self(id: "image-text-to-text", name: "Image & text chat", scope: .vision),
    Self(id: "image-to-text", name: "Image captioning", scope: .vision),
    Self(id: "visual-question-answering", name: "Visual questions", scope: .vision),
    Self(id: "document-question-answering", name: "Document questions", scope: .vision),
    Self(id: "visual-document-retrieval", name: "Visual document retrieval", scope: .vision),
    Self(id: "video-text-to-text", name: "Video understanding", scope: .vision),
    Self(id: "image-classification", name: "Image classification", scope: .vision),
    Self(id: "zero-shot-image-classification", name: "Zero-shot image classification", scope: .vision),
    Self(id: "image-feature-extraction", name: "Image features", scope: .vision),
    Self(id: "object-detection", name: "Object detection", scope: .vision),
    Self(id: "zero-shot-object-detection", name: "Zero-shot object detection", scope: .vision),
    Self(id: "image-segmentation", name: "Image segmentation", scope: .vision),
    Self(id: "mask-generation", name: "Mask generation", scope: .vision),
    Self(id: "depth-estimation", name: "Depth estimation", scope: .vision),
    Self(id: "keypoint-detection", name: "Keypoint detection", scope: .vision),
    Self(id: "image-to-image", name: "Image editing", scope: .vision),
    Self(id: "image-text-to-image", name: "Image & text to image", scope: .vision),
    Self(id: "text-to-image", name: "Image generation", scope: .vision),
    Self(id: "unconditional-image-generation", name: "Unconditional image generation", scope: .vision),
    Self(id: "video-classification", name: "Video classification", scope: .vision),
    Self(id: "text-to-video", name: "Video generation", scope: .vision),
    Self(id: "image-to-video", name: "Image to video", scope: .vision),
    Self(id: "image-text-to-video", name: "Image & text to video", scope: .vision),
    Self(id: "video-to-video", name: "Video editing", scope: .vision),
    Self(id: "image-to-3d", name: "Image to 3D", scope: .vision),
    Self(id: "text-to-3d", name: "Text to 3D", scope: .vision),
    Self(id: "audio-text-to-text", name: "Audio & text chat", scope: .audio),
    Self(id: "automatic-speech-recognition", name: "Speech recognition", scope: .audio),
    Self(id: "text-to-speech", name: "Text to speech", scope: .audio),
    Self(id: "text-to-audio", name: "Audio generation", scope: .audio),
    Self(id: "audio-to-audio", name: "Audio to audio", scope: .audio),
    Self(id: "audio-classification", name: "Audio classification", scope: .audio),
    Self(id: "any-to-any", name: "Multimodal", scope: .all),
  ]

  static func tasks(for scope: ModelDiscoveryScope) -> [Self] {
    all.filter { scope == .all || $0.scope == scope || $0.scope == .all }
  }
}

struct HuggingFaceModelListing: Decodable, Identifiable, Equatable, Sendable {
  let id: String
  var pipelineTag: String? = nil
  var tags: [String]? = nil
  var downloads: Int? = nil
  var likes: Int? = nil

  enum CodingKeys: String, CodingKey { case id, pipelineTag = "pipeline_tag", tags, downloads, likes }

  var hasValidID: Bool {
    id.range(of: "^[A-Za-z0-9_][A-Za-z0-9._-]{0,95}/[A-Za-z0-9_][A-Za-z0-9._-]{0,95}$",
      options: .regularExpression) != nil
  }
  var url: URL { URL(string: "https://huggingface.co")!.appending(path: id) }
  var name: String { String(id.split(separator: "/").last ?? Substring(id)) }
  var publisher: String { String(id.split(separator: "/").first ?? Substring(id)) }
  var tasks: [HuggingFaceTask] {
    let identifiers = Set((tags ?? []) + [pipelineTag].compactMap { $0 })
    return HuggingFaceTask.all.filter { identifiers.contains($0.id) }
  }
  var license: String? { tags?.first { $0.hasPrefix("license:") }.map { String($0.dropFirst(8)) } }
  var isGGUF: Bool { tags?.contains("gguf") == true }
}

struct ModelDiscoveryQuery: Equatable, Sendable {
  var search = ""
  var scope: ModelDiscoveryScope = .all
  var taskID: String? = nil

  var tasks: [HuggingFaceTask] {
    HuggingFaceTask.tasks(for: scope).filter { taskID == nil || $0.id == taskID }
  }

  func url(for task: HuggingFaceTask) -> URL {
    var components = URLComponents(string: "https://huggingface.co/api/models")!
    components.queryItems = [
      URLQueryItem(name: "filter", value: task.id),
      URLQueryItem(name: "sort", value: "downloads"),
      URLQueryItem(name: "direction", value: "-1"),
      URLQueryItem(name: "limit", value: "20"),
    ]
    let text = String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    if !text.isEmpty { components.queryItems?.append(URLQueryItem(name: "search", value: text)) }
    return components.url!
  }
}

struct HuggingFaceModelPage: Sendable {
  let models: [HuggingFaceModelListing]
  var nextURL: URL? = nil
}

enum ModelDiscoveryError: LocalizedError {
  case invalidResponse, responseTooLarge, rateLimited, unavailable
  var errorDescription: String? {
    switch self {
    case .invalidResponse: "Hugging Face returned an unreadable model list. Please try again."
    case .responseTooLarge: "The model list was too large to load. Try a specific task or search."
    case .rateLimited: "Hugging Face is receiving too many requests. Wait a moment, then retry."
    case .unavailable: "Could not reach Hugging Face. Check your connection and retry."
    }
  }
}

final class HuggingFaceModelClient: Sendable {
  static let shared = HuggingFaceModelClient()
  static let maximumResponseBytes = 2_000_000
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 30
    session = URLSession(configuration: configuration, delegate: HuggingFaceRedirectPolicy(), delegateQueue: nil)
  }

  static func isAllowed(_ url: URL) -> Bool {
    url.scheme == "https" && url.host == "huggingface.co" && url.path == "/api/models"
      && url.user == nil && url.password == nil && url.port == nil && url.fragment == nil
      && url.absoluteString.count <= 16_384
  }

  func page(at url: URL) async throws -> HuggingFaceModelPage {
    guard Self.isAllowed(url) else { throw ModelDiscoveryError.invalidResponse }
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, let responseURL = http.url,
          Self.isAllowed(responseURL) else { throw ModelDiscoveryError.invalidResponse }
    guard http.statusCode != 429 else { throw ModelDiscoveryError.rateLimited }
    guard http.statusCode == 200 else { throw ModelDiscoveryError.unavailable }
    guard http.expectedContentLength <= Self.maximumResponseBytes else { throw ModelDiscoveryError.responseTooLarge }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < Self.maximumResponseBytes else { throw ModelDiscoveryError.responseTooLarge }
      data.append(byte)
    }
    return try Self.decode(data, link: http.value(forHTTPHeaderField: "Link"), currentURL: url)
  }

  static func decode(_ data: Data, link: String?, currentURL: URL) throws -> HuggingFaceModelPage {
    guard data.count <= maximumResponseBytes else { throw ModelDiscoveryError.responseTooLarge }
    guard let models = try? JSONDecoder().decode([HuggingFaceModelListing].self, from: data),
          models.count <= 1_000 else { throw ModelDiscoveryError.invalidResponse }
    var next: URL?
    for part in (link ?? "").components(separatedBy: ",") {
      let fields = part.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
      guard fields.dropFirst().contains(where: { $0 == "rel=\"next\"" || $0 == "rel=next" }) else { continue }
      guard let target = fields.first, target.hasPrefix("<"), target.hasSuffix(">"),
            let url = URL(string: String(target.dropFirst().dropLast())), isAllowed(url), url != currentURL else {
        throw ModelDiscoveryError.invalidResponse
      }
      // A cursor may change, but a next page cannot silently change the search.
      let initial = URLComponents(url: currentURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let following = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      for key in ["filter", "search", "sort", "direction", "limit"] {
        guard initial.filter({ $0.name == key }) == following.filter({ $0.name == key }) else {
          throw ModelDiscoveryError.invalidResponse
        }
      }
      next = url
    }
    return HuggingFaceModelPage(models: models.filter(\.hasValidID), nextURL: next)
  }
}

private final class HuggingFaceRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(request.url.map(HuggingFaceModelClient.isAllowed) == true ? request : nil)
  }
}

@MainActor
final class LocalModelDiscovery: ObservableObject {
  typealias Loader = @Sendable (URL) async throws -> HuggingFaceModelPage
  static let featuredModelID = "gemma-4-26b-a4b-q4_k_m"
  @Published private(set) var models: [HuggingFaceModelListing] = []
  @Published private(set) var isLoading = false
  @Published private(set) var notice: String?
  @Published private(set) var hasMore = false
  @Published private(set) var failedTaskCount = 0
  private var pending: [String: URL] = [:]
  private var failed: Set<String> = []
  private var visited: [String: Set<URL>] = [:]
  private var generation = UUID()
  private let loader: Loader

  init(loader: @escaping Loader = { try await HuggingFaceModelClient.shared.page(at: $0) }) {
    self.loader = loader
  }

  func search(_ query: ModelDiscoveryQuery) async {
    guard !Task.isCancelled else { return }
    let token = UUID()
    generation = token
    models = []
    notice = nil
    failed = []
    visited = [:]
    failedTaskCount = 0
    pending = Dictionary(uniqueKeysWithValues: query.tasks.map { ($0.id, query.url(for: $0)) })
    hasMore = !pending.isEmpty
    await fetch(pending, token: token)
  }

  func loadMore() async {
    guard !isLoading else { return }
    await fetch(pending, token: generation)
  }

  func retry() async {
    guard !isLoading else { return }
    await fetch(pending.filter { failed.contains($0.key) }, token: generation)
  }

  private func fetch(_ pages: [String: URL], token: UUID) async {
    guard !pages.isEmpty, !Task.isCancelled else { return }
    isLoading = true
    notice = nil
    let loader = loader
    // Limit simultaneous public API requests even when browsing every task.
    await withTaskGroup(of: (String, URL, Result<HuggingFaceModelPage, Error>).self) { group in
      var remaining = pages.sorted { $0.key < $1.key }.makeIterator()
      func enqueue() {
        guard !Task.isCancelled, let (id, url) = remaining.next() else { return }
        group.addTask {
          do { return (id, url, .success(try await loader(url))) }
          catch { return (id, url, .failure(error)) }
        }
      }
      for _ in 0..<4 { enqueue() }
      for await (id, url, result) in group {
        guard generation == token, !Task.isCancelled else { group.cancelAll(); continue }
        switch result {
        case .success(let page):
          visited[id, default: []].insert(url)
          if let next = page.nextURL, visited[id, default: []].contains(next) {
            failed.insert(id)
            notice = ModelDiscoveryError.invalidResponse.localizedDescription
          } else {
            failed.remove(id)
            pending[id] = page.nextURL
          }
          var byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
          for model in page.models where model.hasValidID { byID[model.id] = model }
          models = byID.values.sorted {
            if ($0.downloads ?? 0) != ($1.downloads ?? 0) { return ($0.downloads ?? 0) > ($1.downloads ?? 0) }
            return $0.id < $1.id
          }
        case .failure(let error):
          failed.insert(id)
          notice = (error as? ModelDiscoveryError ?? .unavailable).localizedDescription
        }
        failedTaskCount = failed.count
        hasMore = !pending.isEmpty
        enqueue()
      }
    }
    guard generation == token else { return }
    isLoading = false
  }
}
