import Combine
import Foundation

@MainActor
final class StartPreferences: ObservableObject {
  static let shared = StartPreferences()
  static let modeKey = "startup.preferredMode"
  static let sidebarKey = "startup.showSidebar"
  private let defaults: UserDefaults

  @Published var mode: ChatMode {
    didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
  }
  @Published var showsSidebar: Bool {
    didSet { defaults.set(showsSidebar, forKey: Self.sidebarKey) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    mode = defaults.string(forKey: Self.modeKey).flatMap(ChatMode.init(rawValue:)) ?? .auto
    showsSidebar = defaults.object(forKey: Self.sidebarKey) as? Bool ?? false
  }
}
