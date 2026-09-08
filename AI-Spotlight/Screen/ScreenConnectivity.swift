import Combine
import Network

@MainActor
final class ScreenConnectivity: ObservableObject {
  static let shared = ScreenConnectivity()
  @Published private(set) var isOffline = false
  private let monitor = NWPathMonitor()
  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      let offline = path.status != .satisfied
      Task { @MainActor in self?.isOffline = offline }
    }
    monitor.start(queue: DispatchQueue(label: "aiSpotlight.screen.connectivity"))
  }
}
