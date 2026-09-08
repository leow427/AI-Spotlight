import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
  private var menuBarController: MenuBarController?
  private var panelController: SpotlightPanelController?
  private var globalHotKeyMonitors: [GlobalHotKeyMonitor] = []
  private var selectionShortcut: SelectionShortcutMonitor?
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
    // Hosted unit tests create their own controllers and credential fixtures.
    // Starting the real panel here can prompt for personal Keychain entries and
    // show first-run onboarding before XCTest has started executing tests.
    #if DEBUG
    if NSClassFromString("XCTestCase") != nil { return }
    #endif
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

    let togglePanelHotKeyMonitor = GlobalHotKeyMonitor(hotKey: .togglePanel) { [weak self] in
      self?.selectionShortcut?.reset()
      panelController.toggle()
    }
    do {
      try togglePanelHotKeyMonitor.start()
      globalHotKeyMonitors.append(togglePanelHotKeyMonitor)
    } catch {
      NSLog("Unable to register the AI Spotlight shortcut: %@", error.localizedDescription)
    }

    let openSettingsHotKeyMonitor = GlobalHotKeyMonitor(hotKey: .openSettings) { [weak self] in
      self?.selectionShortcut?.reset()
      self?.openSettings()
    }
    do {
      try openSettingsHotKeyMonitor.start()
      globalHotKeyMonitors.append(openSettingsHotKeyMonitor)
    } catch {
      NSLog("Unable to register the AI Spotlight settings shortcut: %@", error.localizedDescription)
    }

    let selectionShortcut = SelectionShortcutMonitor { panelController.summonSelectionContext() }
    selectionShortcut.start()
    self.selectionShortcut = selectionShortcut
    let selectionBackup = GlobalHotKeyMonitor(hotKey: .selectionContext) { [weak self] in
      self?.selectionShortcut?.reset()
      panelController.summonSelectionContext()
    }
    do {
      try selectionBackup.start()
      globalHotKeyMonitors.append(selectionBackup)
    } catch {
      NSLog("Unable to register Selection Context shortcut: %@", error.localizedDescription)
    }

    self.panelController = panelController
    self.menuBarController = menuBarController

    panelController.show()
  }

  func applicationWillTerminate(_ notification: Notification) {
    NotificationCenter.default.removeObserver(self)
    selectionShortcut?.stop()
    globalHotKeyMonitors.forEach { $0.stop() }
    globalHotKeyMonitors.removeAll()
  }

  @objc func openSettings() {
    guard panelController?.isCapturingScreen != true else { return }
    if settingsWindowController == nil {
      settingsWindowController = SettingsWindowController()
    }
    settingsWindowController?.showSettings()
  }
}
