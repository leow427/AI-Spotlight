import AppKit
import SwiftUI

@main
struct AISpotlightApp: App {
  @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate

  var body: some Scene {
    Settings {
      SettingsView()
    }
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
          NotificationCenter.default.post(name: .settingsRequested, object: nil)
        }
        .keyboardShortcut(",", modifiers: .command)
      }
    }
  }
}

@MainActor
final class SettingsWindowController: NSWindowController {
  convenience init() {
    self.init(contentView: NSHostingView(rootView: SettingsView()))
  }

  init(contentView: NSView) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 740),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "AI Spotlight Settings"
    // Match the chat panel's level so Settings can appear in front without hiding it.
    window.level = .floating
    window.isReleasedWhenClosed = false
    window.contentView = contentView
    window.center()
    super.init(window: window)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func showSettings() {
    // The chat's standalone NSHostingView has no SwiftUI settings-scene action.
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
    window?.deminiaturize(nil)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
}
