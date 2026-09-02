import Combine
import Foundation

final class GlassAppearanceSettings: ObservableObject {
  private enum Key {
    static let isEnabled = "aiSpotlight.glassAppearance.isEnabled"
    static let opacity = "aiSpotlight.glassAppearance.opacity"
  }

  @Published var isEnabled: Bool
  @Published var opacity: Double

  private let defaults: UserDefaults
  private var savedIsEnabled: Bool
  private var savedOpacity: Double

  var hasUnsavedChanges: Bool {
    isEnabled != savedIsEnabled || opacity != savedOpacity
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults

    let isEnabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
    let opacity = Self.normalized(defaults.object(forKey: Key.opacity) as? Double ?? 0.78)

    self.isEnabled = isEnabled
    self.opacity = opacity
    savedIsEnabled = isEnabled
    savedOpacity = opacity
  }

  func save() {
    opacity = Self.normalized(opacity)
    defaults.set(isEnabled, forKey: Key.isEnabled)
    defaults.set(opacity, forKey: Key.opacity)
    savedIsEnabled = isEnabled
    savedOpacity = opacity
  }

  private static func normalized(_ value: Double) -> Double {
    min(max(value, 0.15), 1)
  }
}
