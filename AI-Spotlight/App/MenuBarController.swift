import AppKit

@MainActor
final class MenuBarController: NSObject {
  private var statusItem: NSStatusItem?

  func install() {
    guard statusItem == nil else { return }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      button.image = NSImage(
        systemSymbolName: "sparkles",
        accessibilityDescription: "AI Spotlight"
      )
      button.toolTip = "AI Spotlight"
    }

    let menu = NSMenu()
    menu.addItem(makeItem(.open, action: #selector(openApp)))
    menu.addItem(makeItem(.newChat, action: #selector(startNewChat)))
    menu.addItem(makeItem(.privacyHide, action: #selector(hideApp)))
    menu.addItem(.separator())
    menu.addItem(makeItem(.settings, action: #selector(openSettings)))
    menu.addItem(.separator())
    menu.addItem(makeItem(.quit, action: #selector(quitApp)))
    item.menu = menu

    statusItem = item
  }

  private func makeItem(_ command: AppCommand, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: command.rawValue, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  @objc private func openApp() {
    revealMainWindow()
  }

  @objc private func startNewChat() {
    revealMainWindow()
    NotificationCenter.default.post(name: .newChatRequested, object: nil)
  }

  @objc private func hideApp() {
    NSApp.hide(nil)
  }

  @objc private func openSettings() {
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }

  private func revealMainWindow() {
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)

    let mainWindow = NSApp.windows.first { window in
      window.canBecomeMain && window.title == "AI Spotlight"
    }
    mainWindow?.makeKeyAndOrderFront(nil)
  }
}
