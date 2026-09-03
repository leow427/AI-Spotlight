import SwiftUI

@main
struct AISpotlightApp: App {
  @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate

  var body: some Scene {
    Settings {
      SettingsView()
    }
  }
}
