import AppKit

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
  private var menuBarController: MenuBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    let menuBarController = MenuBarController()
    menuBarController.install()
    self.menuBarController = menuBarController
  }
}
