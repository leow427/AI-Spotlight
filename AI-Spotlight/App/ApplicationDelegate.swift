import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
  private var menuBarController: MenuBarController?
  private var panelController: SpotlightPanelController?
  private var globalHotKeyMonitors: [GlobalHotKeyMonitor] = []
  private var settingsWindowController: SettingsWindowController?

  override init() {
    super.init()
  }

  init(
    panelController: SpotlightPanelController,
    settingsWindowController: SettingsWindowController
  ) {
    self.panelController = panelController
    self.settingsWindowController = settingsWindowController
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(openSettings),
      name: .settingsRequested,
      object: nil
    )

    let panelController = SpotlightPanelController(
      glassAppearance: GlassAppearanceSettings()
    )
    let menuBarController = MenuBarController(panelController: panelController)
    menuBarController.install()

    let togglePanelHotKeyMonitor = GlobalHotKeyMonitor(hotKey: .togglePanel) {
      panelController.toggle()
    }
    do {
      try togglePanelHotKeyMonitor.start()
      globalHotKeyMonitors.append(togglePanelHotKeyMonitor)
    } catch {
      NSLog("Unable to register the AI Spotlight shortcut: %@", error.localizedDescription)
    }

    let openSettingsHotKeyMonitor = GlobalHotKeyMonitor(hotKey: .openSettings) { [weak self] in
      self?.openSettings()
    }
    do {
      try openSettingsHotKeyMonitor.start()
      globalHotKeyMonitors.append(openSettingsHotKeyMonitor)
    } catch {
      NSLog("Unable to register the AI Spotlight settings shortcut: %@", error.localizedDescription)
    }

    self.panelController = panelController
    self.menuBarController = menuBarController

    panelController.show()
  }

  func applicationWillTerminate(_ notification: Notification) {
    NotificationCenter.default.removeObserver(self)
    globalHotKeyMonitors.forEach { $0.stop() }
    globalHotKeyMonitors.removeAll()
  }

  @objc func openSettings() {
    if settingsWindowController == nil {
      settingsWindowController = SettingsWindowController()
    }
    settingsWindowController?.showSettings()
  }
}
