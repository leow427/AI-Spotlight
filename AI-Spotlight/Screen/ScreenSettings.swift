import AppKit
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

/// Consent is checked again when returning from System Settings; opening it grants nothing.
struct MacPermissionControls: View {
  @ObservedObject private var selection = SelectionAccessibilityAccess.shared
  @State private var screenGranted = CGPreflightScreenCaptureAccess()
  var showScreen = true

  static func openScreenSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      permission(title: "Accessibility", enabled: selection.isGranted,
        explanation: "Required to attach selected text with double-Option and replace text in other apps.",
        button: "Open Accessibility Settings…", action: selection.requestAccess)
      if showScreen {
        Divider()
        permission(title: "Screen Recording", enabled: screenGranted,
          explanation: "Required for /screen and /snapshot. Captures happen only when you request them.",
          button: "Open Screen Recording Settings…", action: Self.openScreenSettings)
      }
      Text("Enable \(SelectionAccessibilityAccess.appName) in System Settings. If an older copy is already listed, remove it and add the app you’re running, then quit and reopen Enigma.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onAppear { refresh() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    .onReceive(NotificationCenter.default.publisher(for: .panelPresented)) { _ in refresh() }
    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in refresh() }
  }

  private func refresh() {
    selection.refresh()
    screenGranted = CGPreflightScreenCaptureAccess()
  }

  private func permission(title: String, enabled: Bool, explanation: String, button: String,
                          action: @escaping () -> Void) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("\(title) · \(enabled ? "Enabled" : "Action needed")",
        systemImage: enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .font(.headline).foregroundStyle(enabled ? Color.green : Color.orange)
      Text(explanation).font(.subheadline)
      Button(button, action: action).buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
