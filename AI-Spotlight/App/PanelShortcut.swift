import AppKit

enum PanelShortcut: Equatable {
  case newChat
  case modePalette
  case stopStreaming
  case cycleRecentChat

  static func resolve(
    characters: String?,
    modifiers: NSEvent.ModifierFlags
  ) -> PanelShortcut? {
    let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    let relevantModifiers = modifiers.intersection(shortcutModifiers)
    if relevantModifiers == .control, characters == "\t" {
      return .cycleRecentChat
    }
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
