import AppKit
import ApplicationServices
import Carbon

enum SelectionModifier: String, CaseIterable, Identifiable {
  case option, command, shift
  var id: Self { self }
  var title: String { rawValue.capitalized }
  var symbol: String { switch self { case .option: "⌥"; case .command: "⌘"; case .shift: "⇧" } }
  var flags: NSEvent.ModifierFlags { switch self { case .option: .option; case .command: .command; case .shift: .shift } }
  var keyCodes: [UInt16] { switch self { case .option: [58, 61]; case .command: [54, 55]; case .shift: [56, 60] } }
}

struct OptionDoubleTap {
  var modifier: SelectionModifier = .option
  var interval: TimeInterval = 0.35
  private var pressedAt: TimeInterval?
  private var releasedAt: TimeInterval?
  private var pressedKey: UInt16?

  mutating func reset() { pressedAt = nil; releasedAt = nil; pressedKey = nil }

  mutating func flagsChanged(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, timestamp: TimeInterval) -> Bool {
    let flags = modifiers.intersection([.option, .command, .control, .shift, .function, .capsLock])
    guard modifier.keyCodes.contains(keyCode), flags.isEmpty || flags == modifier.flags else { reset(); return false }
    if flags == modifier.flags {
      guard pressedAt == nil else { reset(); return false }
      pressedAt = timestamp
      pressedKey = keyCode
      return false
    }
    guard let down = pressedAt, pressedKey == keyCode, timestamp >= down, timestamp - down <= 0.25 else {
      reset(); return false
    }
    pressedAt = nil
    pressedKey = nil
    if let previous = releasedAt, down >= previous, timestamp - previous <= interval {
      reset(); return true
    }
    releasedAt = timestamp
    return false
  }
}

@MainActor
final class SelectionShortcutMonitor {
  static let modifierKey = "enigma.selection.modifier"
  static let enabledKey = "enigma.selection.doubleOption.enabled"
  static let intervalKey = "enigma.selection.doubleOption.interval"
  private var accessibilityGranted = false
  private var activationObserver: NSObjectProtocol?
  private var global: Any?
  private var local: Any?
  private var detector = OptionDoubleTap()
  private let handler: @MainActor () -> Void

  init(handler: @escaping @MainActor () -> Void) { self.handler = handler }

  func reset() { detector.reset() }

  func start() {
    accessibilityGranted = AXIsProcessTrusted()
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.reset()
          SelectionAccessibilityAccess.shared.refresh()
          if self.accessibilityGranted != AXIsProcessTrusted() {
            self.stop()
            self.start()
          }
        }
      }
    let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
    global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.receive(event) }
    local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      self?.receive(event)
      return event
    }
  }

  func stop() {
    if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    activationObserver = nil
    if let global { NSEvent.removeMonitor(global) }
    if let local { NSEvent.removeMonitor(local) }
    global = nil; local = nil; detector.reset()
  }

  private func receive(_ event: NSEvent) {
    guard UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true,
          !IsSecureEventInputEnabled() else { detector.reset(); return }
    let modifier = SelectionModifier(rawValue: UserDefaults.standard.string(forKey: Self.modifierKey) ?? "option") ?? .option
    if detector.modifier != modifier { detector.reset(); detector.modifier = modifier }
    let configured = UserDefaults.standard.double(forKey: Self.intervalKey)
    detector.interval = configured >= 0.2 && configured <= 0.6 ? configured : 0.35
    guard event.type == .flagsChanged else { detector.reset(); return }
    if detector.flagsChanged(keyCode: event.keyCode, modifiers: event.modifierFlags, timestamp: event.timestamp) {
      handler()
    }
  }
}
