import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
  private var menuBarController: MenuBarController?
  private var panelController: SpotlightPanelController?
  private var globalHotKeyMonitor: GlobalHotKeyMonitor?
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

    let globalHotKeyMonitor = GlobalHotKeyMonitor {
      panelController.toggle()
    }
    do {
      try globalHotKeyMonitor.start()
    } catch {
      NSLog("Unable to register the AI Spotlight shortcut: %@", error.localizedDescription)
    }

    self.panelController = panelController
    self.menuBarController = menuBarController
    self.globalHotKeyMonitor = globalHotKeyMonitor

    panelController.show()
  }

  func applicationWillTerminate(_ notification: Notification) {
    NotificationCenter.default.removeObserver(self)
    globalHotKeyMonitor?.stop()
  }

  @objc func openSettings() {
    if settingsWindowController == nil {
      settingsWindowController = SettingsWindowController()
    }
    settingsWindowController?.showSettings()
  }
}
