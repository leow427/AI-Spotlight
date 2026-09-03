import AppKit

enum PanelShortcut: Equatable {
  case newChat
  case modePalette
  case stopStreaming

  static func resolve(
    characters: String?,
    modifiers: NSEvent.ModifierFlags
  ) -> PanelShortcut? {
    let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    let relevantModifiers = modifiers.intersection(shortcutModifiers)
    guard relevantModifiers == .command else { return nil }

    switch characters?.lowercased() {
    case "n":
      return .newChat
    case "k":
      return .modePalette
    case ".":
      return .stopStreaming
    default:
      return nil
    }
  }
}
