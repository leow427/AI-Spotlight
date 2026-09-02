import SwiftUI

@main
struct AISpotlightApp: App {
  @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
  @StateObject private var glassAppearance = GlassAppearanceSettings()

  var body: some Scene {
    Window("AI Spotlight", id: "main") {
      AppShellView(glassAppearance: glassAppearance)
        .containerBackground(.clear, for: .window)
      }
      .defaultSize(width: 760, height: 520)
      .windowStyle(.plain)

      Settings {
      SettingsView()
    }
  }
}
