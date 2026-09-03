import Foundation

enum AppCommand: String, CaseIterable {
  case open = "Open"
  case newChat = "New Chat"
  case privacyHide = "Privacy Hide"
  case settings = "Settings"
  case quit = "Quit"
}

extension Notification.Name {
  static let settingsRequested = Notification.Name("aiSpotlight.settingsRequested")
  static let newChatRequested = Notification.Name("aiSpotlight.newChatRequested")
  static let modePaletteRequested = Notification.Name("aiSpotlight.modePaletteRequested")
  static let panelHidden = Notification.Name("aiSpotlight.panelHidden")
  static let panelPresented = Notification.Name("aiSpotlight.panelPresented")
  static let stopStreamingRequested = Notification.Name("aiSpotlight.stopStreamingRequested")
  static let recentChatCycleRequested = Notification.Name("aiSpotlight.recentChatCycleRequested")
}
