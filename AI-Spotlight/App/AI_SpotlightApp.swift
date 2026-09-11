import AppKit
import SwiftUI

@main
struct EnigmaApp: App {
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
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Enigma Settings"
    window.appearance = NSAppearance(named: .darkAqua)
    window.titlebarAppearsTransparent = true
    window.backgroundColor = NSColor(NatureGlass.forestTop)
    // Apply the same best-effort capture exclusion as the chat panel.
    window.sharingType = .none
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

  func showSettings(destination: SettingsView.SettingsDestination? = nil) {
    // The chat's standalone NSHostingView has no SwiftUI settings-scene action.
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
    window?.deminiaturize(nil)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    if let destination {
      window?.contentView?.layoutSubtreeIfNeeded()
      NotificationCenter.default.post(name: .settingsDestinationRequested, object: destination)
    }
  }
}
