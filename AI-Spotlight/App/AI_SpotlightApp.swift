import SwiftUI

@main
struct AISpotlightApp: App {
  @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
  @StateObject private var glassAppearance = GlassAppearanceSettings()

  var body: some Scene {
    Window("AI Spotlight", id: "main") {
      AppShellView(glassAppearance: glassAppearance)
        .containerBackground(for: .window) {
          if glassAppearance.isEnabled {
            Rectangle()
              .fill(.ultraThinMaterial)
              .opacity(1 - glassAppearance.clarity)
          } else {
            Rectangle()
              .fill(.background)
          }
        }
    }
    .defaultSize(width: 760, height: 520)
    .windowStyle(.hiddenTitleBar)

    Settings {
      SettingsView()
    }
  }
}
