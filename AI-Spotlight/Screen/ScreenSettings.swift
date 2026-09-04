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
  @Published var cloudVisionProvider: CloudProviderID {
    didSet { defaults.set(cloudVisionProvider.rawValue, forKey: "screen.cloudVisionProvider") }
  }
  @Published var cloudVisionModelID: String {
    didSet { defaults.set(cloudVisionModelID, forKey: "screen.cloudVisionModelID") }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    allowCloudScreenshots = defaults.bool(forKey: "screen.allowCloudScreenshots")
    hasExplainedCloudPermission = defaults.bool(forKey: "screen.hasExplainedCloudPermission")
    cloudVisionProvider = defaults.string(forKey: "screen.cloudVisionProvider").flatMap(CloudProviderID.init(rawValue:)) ?? .openAI
    cloudVisionModelID = defaults.string(forKey: "screen.cloudVisionModelID") ?? "gpt-4.1-mini"
  }

  func answerCloudPermission(allow: Bool) {
    hasExplainedCloudPermission = true
    allowCloudScreenshots = allow
  }

  var configuredVisionModel: CloudModel {
    CloudModel(id: cloudVisionModelID, displayName: cloudVisionModelID, provider: cloudVisionProvider)
  }

  static let permissionExplanation = "Text is read locally first. This question needs the image itself. Allowing screenshots sends the selected region to your configured cloud vision provider, where that provider’s data policies apply. This setting applies to future screenshots and can be turned off in Settings. Local mode always keeps screenshots on this Mac."
}

struct ScreenSettingsSection: View {
  @ObservedObject var settings: ScreenSettings
  var body: some View {
    Section("Screen") {
      Toggle("Allow screenshots to be sent to cloud models", isOn: $settings.allowCloudScreenshots)
      Text("Off by default. OCR runs on this Mac. In Auto or Cloud, extracted text may be sent to your text model. Actual screenshot images require this permission; Local mode stays local.")
        .font(.caption).foregroundStyle(.secondary)
      Picker("Cloud vision provider", selection: $settings.cloudVisionProvider) {
        ForEach(CloudProviderID.allCases.filter { !CloudModelCapabilities.visionModelIDs(for: $0).isEmpty }) { provider in
          Text(provider.displayName).tag(provider)
        }
      }
      .onChange(of: settings.cloudVisionProvider) { _, provider in
        settings.cloudVisionModelID = CloudModelCapabilities.visionModelIDs(for: provider).first ?? ""
      }
      Picker("Cloud vision model", selection: $settings.cloudVisionModelID) {
        ForEach(CloudModelCapabilities.visionModelIDs(for: settings.cloudVisionProvider), id: \.self) { id in
          Text(id).tag(id)
        }
      }
      Text("Uses the provider key in Advanced Cloud Settings. The normal text model remains selected for text-heavy captures. Import a local vision model in the Local Models tab for offline visual analysis.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}
