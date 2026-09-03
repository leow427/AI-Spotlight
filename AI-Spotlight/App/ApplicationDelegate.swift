import AppKit

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
  private var menuBarController: MenuBarController?
  private var panelController: SpotlightPanelController?
  private var globalHotKeyMonitor: GlobalHotKeyMonitor?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

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
    globalHotKeyMonitor?.stop()
  }
}
