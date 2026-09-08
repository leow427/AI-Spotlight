import AppKit

enum PanelShortcut: Equatable {
  case newChat
  case modePalette
  case stopStreaming
  case cycleRecentChat
  case settings
  case hideInactiveTools
  case toggleSidebar
  case fileMode

  static func resolve(
    characters: String?,
    modifiers: NSEvent.ModifierFlags
  ) -> PanelShortcut? {
    let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    let relevantModifiers = modifiers.intersection(shortcutModifiers)
    if relevantModifiers == [.shift, .option], characters?.lowercased() == "f" { return .fileMode }
    if relevantModifiers == .control, characters == "\t" {
      return .cycleRecentChat
    }
    if relevantModifiers == [.command, .shift], characters?.lowercased() == "h" {
      return .hideInactiveTools
    }
    guard relevantModifiers == .command else { return nil }

    switch characters?.lowercased() {
    case "n":
      return .newChat
    case "k":
      return .modePalette
    case ".":
      return .stopStreaming
    case ",":
      return .settings
    default:
      return nil
    }
  }
}

/// Recognizes two short, unmodified Control taps. Key chords and clicks cancel
/// the sequence, so Control-Tab and Control-click keep their normal behavior.
struct ControlDoubleTap {
  private var pressedAt: TimeInterval?
  private var releasedAt: TimeInterval?
  private let interval: TimeInterval = 0.4

  mutating func reset() {
    pressedAt = nil
    releasedAt = nil
  }

  mutating func flagsChanged(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, timestamp: TimeInterval) -> Bool {
    let relevant = modifiers.intersection([.control, .command, .option, .shift])
    guard [59, 62].contains(keyCode), relevant.isEmpty || relevant == .control else {
      reset()
      return false
    }
    if relevant == .control {
      guard pressedAt == nil else { reset(); return false }
      pressedAt = timestamp
      return false
    }
    guard let pressedAt, timestamp >= pressedAt, timestamp - pressedAt <= interval else {
      reset()
      return false
    }
    self.pressedAt = nil
    if let releasedAt, pressedAt >= releasedAt, timestamp - releasedAt <= interval {
      reset()
      return true
    }
    releasedAt = timestamp
    return false
  }
}
