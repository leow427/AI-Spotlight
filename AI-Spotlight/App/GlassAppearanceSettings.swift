import Combine
import Foundation

final class GlassAppearanceSettings: ObservableObject {
  private enum Key {
    static let isEnabled = "aiSpotlight.glassAppearance.isEnabled"
    static let clarity = "aiSpotlight.glassAppearance.clarity"
    static let legacyOpacity = "aiSpotlight.glassAppearance.opacity"
  }

  @Published var isEnabled: Bool
  @Published var clarity: Double

  private let defaults: UserDefaults
  private var savedIsEnabled: Bool
  private var savedClarity: Double

  var hasUnsavedChanges: Bool {
    isEnabled != savedIsEnabled || clarity != savedClarity
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults

    let isEnabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
    let clarity: Double
    if let storedClarity = defaults.object(forKey: Key.clarity) as? Double {
      clarity = Self.normalized(storedClarity)
    } else {
      let legacyOpacity = defaults.object(forKey: Key.legacyOpacity) as? Double ?? 0.78
      clarity = 1 - Self.normalized(legacyOpacity)
    }

    self.isEnabled = isEnabled
    self.clarity = clarity
    savedIsEnabled = isEnabled
    savedClarity = clarity
  }

  func save() {
    clarity = Self.normalized(clarity)
    defaults.set(isEnabled, forKey: Key.isEnabled)
    defaults.set(clarity, forKey: Key.clarity)
    defaults.removeObject(forKey: Key.legacyOpacity)
    savedIsEnabled = isEnabled
    savedClarity = clarity
  }

  private static func normalized(_ value: Double) -> Double {
    min(max(value, 0), 1)
  }
}
