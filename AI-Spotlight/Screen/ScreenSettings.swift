import Combine
import Foundation
import SwiftUI

@MainActor
final class ScreenSettings: ObservableObject {
  static let shared = ScreenSettings()
  private let defaults: UserDefaults
  @Published var allowCloudScreenshots: Bool {
    didSet {
      defaults.set(allowCloudScreenshots, forKey: "screen.allowCloudScreenshots")
      if allowCloudScreenshots { hasExplainedCloudPermission = true }
    }
  }
  @Published private(set) var hasExplainedCloudPermission: Bool {
    didSet { defaults.set(hasExplainedCloudPermission, forKey: "screen.hasExplainedCloudPermission") }
  }
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // Retire only the obsolete preference. The normal library selection and all
    // installed model/projector files are preserved; migration never downloads.
    defaults.removeObject(forKey: "screen.localVisionModelID")
    allowCloudScreenshots = defaults.bool(forKey: "screen.allowCloudScreenshots")
    hasExplainedCloudPermission = defaults.bool(forKey: "screen.hasExplainedCloudPermission")

  }

  func answerCloudPermission(allow: Bool) {
    hasExplainedCloudPermission = true
    allowCloudScreenshots = allow
  }

  static let permissionExplanation = "Text is read locally first. This question needs the image itself. Allowing screenshots sends the selected region to your selected cloud provider, where that provider’s data policies apply. This setting applies to future screenshots and can be turned off in Settings. Local mode always keeps screenshots on this Mac."
}

struct ScreenSettingsSection: View {
  @ObservedObject var settings: ScreenSettings
  var body: some View {
    Section("Screen") {
      Toggle("Allow screenshots to be sent to cloud models", isOn: $settings.allowCloudScreenshots)
      Text("Off by default. OCR runs on this Mac. In Auto or Cloud, extracted text may be sent to your text model. Actual screenshot images require this permission; Local mode stays local.")
        .font(.caption).foregroundStyle(.secondary)
      Text("The normal model picker selects the model for text and images. Install a recommended package in Local Models for private visual analysis.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}
