import SwiftUI

@main
struct AISpotlightApp: App {
  @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate

  var body: some Scene {
    Window("AI Spotlight", id: "main") {
      AppShellView()
    }
    .defaultSize(width: 760, height: 520)

    Settings {
      SettingsView()
    }
  }
}
