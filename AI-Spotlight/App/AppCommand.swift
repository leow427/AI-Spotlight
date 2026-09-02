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
}
