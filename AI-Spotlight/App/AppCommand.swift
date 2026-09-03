import Foundation

enum AppCommand: String, CaseIterable {
  case open = "Open"
  case newChat = "New Chat"
  case privacyHide = "Privacy Hide"
  case settings = "Settings"
  case quit = "Quit"
}

extension Notification.Name {
  static let newChatRequested = Notification.Name("aiSpotlight.newChatRequested")
  static let modePaletteRequested = Notification.Name("aiSpotlight.modePaletteRequested")
  static let panelPresented = Notification.Name("aiSpotlight.panelPresented")
  static let stopStreamingRequested = Notification.Name("aiSpotlight.stopStreamingRequested")
}
