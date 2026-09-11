import Foundation

enum AppCommand: String, CaseIterable {
  case open = "Open"
  case newChat = "New Chat"
  case privacyHide = "Privacy Hide"
  case settings = "Settings"
  case quit = "Quit"
}

extension Notification.Name {
  static let selectionReplacementBegan = Notification.Name("enigma.selectionReplacementBegan")
  static let selectionReplacementEnded = Notification.Name("enigma.selectionReplacementEnded")
  static let selectionContextRequested = Notification.Name("enigma.selectionContextRequested")
  static let sidebarToggleRequested = Notification.Name("aiSpotlight.sidebarToggleRequested")
  static let fileModeRequested = Notification.Name("aiSpotlight.fileModeRequested")
  static let settingsRequested = Notification.Name("aiSpotlight.settingsRequested")
  static let settingsDestinationRequested = Notification.Name("enigma.settingsDestinationRequested")
  static let newChatRequested = Notification.Name("aiSpotlight.newChatRequested")
  static let modePaletteRequested = Notification.Name("aiSpotlight.modePaletteRequested")
  static let panelHidden = Notification.Name("aiSpotlight.panelHidden")
  static let panelPresented = Notification.Name("aiSpotlight.panelPresented")
  static let stopStreamingRequested = Notification.Name("aiSpotlight.stopStreamingRequested")
  static let hideInactiveToolsRequested = Notification.Name("aiSpotlight.hideInactiveToolsRequested")
  static let recentChatCycleRequested = Notification.Name("aiSpotlight.recentChatCycleRequested")
}
