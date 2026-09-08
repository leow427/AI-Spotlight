import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Combine

/// A lossless eager snapshot: decline clipboard use if any representation cannot be read.
@MainActor
struct SelectionPasteboardSnapshot {
  let items: [[NSPasteboard.PasteboardType: Data]]

  init?(_ board: NSPasteboard) {
    let changeCount = board.changeCount
    var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
    for item in board.pasteboardItems ?? [] {
      var values: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types {
        guard let data = item.data(forType: type) else { return nil }
        values[type] = data
      }
      snapshot.append(values)
    }
    guard board.changeCount == changeCount else { return nil }
    items = snapshot
  }

  func restore(_ board: NSPasteboard, ifUnchanged count: Int) {
    guard board.changeCount == count else { return }
    board.clearContents()
    let restored = items.map { values in
      let item = NSPasteboardItem()
      for (type, data) in values { item.setData(data, forType: type) }
      return item
    }
    if !restored.isEmpty { board.writeObjects(restored) }
  }
}

@MainActor
final class SelectionContextService: ObservableObject {
  static let shared = SelectionContextService()
  @Published private(set) var isWorking = false
  @Published var notice: String?
  private var target: Target?
  private var capturedBounds: NSRect?

  private struct Target {
    let contextID: UUID
    let app: NSRunningApplication
    let element: AXUIElement
    let window: AXUIElement
    let range: CFRange
    let text: String
    let capturedAt: Date
  }

  var canReplace: Bool { target != nil && !isWorking }
  func discardTarget() { target = nil; capturedBounds = nil; notice = nil }

  func capture() async -> ConversationContext? {
    guard !isWorking else { return nil }
    isWorking = true
    defer { isWorking = false }
    discardTarget()
    let interaction = SelectionInteractionGuard()
    defer { interaction.stop() }
    guard NSApp.keyWindow?.isKeyWindow != true, let app = NSWorkspace.shared.frontmostApplication,
          app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
    guard AXIsProcessTrusted() else {
      notice = "Enable Accessibility in Help to attach selected text. This temporary chat is still ready."
      return nil
    }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.15)
    guard !IsSecureEventInputEnabled(), let element = element(application, kAXFocusedUIElementAttribute),
          isSafe(element) else { return nil }
    let range = selectedRange(element)
    var text = selectedText(element)
    // Some editors expose a text range but not AXSelectedText.
    if text == nil, let range { text = textForRange(element, range: range) }
    if text == nil || text?.isEmpty == true {
      guard SelectionCapturePolicy.allowsCopy(range: range, bundleID: app.bundleIdentifier) else { return nil }
      text = await copySelection(app: app, element: element)
    }
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !interaction.interrupted, sameFocus(app: app, element: element), isSafe(element) else { return nil }
    guard text.utf8.count <= 256_000 else {
      notice = "The selection is too large to attach. Select a smaller passage and try again."
      return nil
    }
    if let range, range.length > 0 { capturedBounds = bounds(element: element, range: range) }
    let context = ConversationContext(sourceName: app.localizedName ?? "Application", text: text)
    if let range, range.length > 0, isEditable(element), let window = self.element(element, kAXWindowAttribute) {
      target = Target(contextID: context.id, app: app, element: element, window: window,
                      range: range, text: text, capturedAt: .now)
    }
    return context
  }

  func selectionBounds() -> NSRect? { capturedBounds }

  private func bounds(element: AXUIElement, range: CFRange) -> NSRect? {
    var range = range
    guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
    var result: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
      parameter, &result) == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(result as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0,
          let primary = NSScreen.screens.first else { return nil }
    return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
  }

  /// Never reselect text. Revalidate the still-selected range, field, window and text.
  func replace(with text: String, contextID: UUID) async -> Bool {
    guard !isWorking, let target, target.contextID == contextID,
          !text.isEmpty, text.utf8.count <= 256_000 else { return false }
    isWorking = true
    defer { isWorking = false }
    let interaction = SelectionInteractionGuard()
    defer { interaction.stop() }
    guard SelectionReplacementPolicy.isFresh(capturedAt: target.capturedAt, now: .now), !target.app.isTerminated,
          AXIsProcessTrusted(), isSafe(target.element) else { return refuseReplacement() }
    target.app.activate(options: [])
    for _ in 0..<15 {
      if sameFocus(app: target.app, element: target.element) { break }
      try? await Task.sleep(for: .milliseconds(20))
    }
    guard await validate(target), !interaction.interrupted else { return refuseReplacement() }
    var settable = DarwinBoolean(false)
    if AXUIElementIsAttributeSettable(target.element, kAXSelectedTextAttribute as CFString, &settable) == .success,
       settable.boolValue {
      // A failed write can be ambiguous; never follow it with a second mutation.
      guard AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
        return refuseReplacement()
      }
    } else {
      let board = NSPasteboard.general
      guard let snapshot = SelectionPasteboardSnapshot(board), await validate(target), !interaction.interrupted else { return refuseReplacement() }
      board.clearContents()
      board.setString(text, forType: .string)
      let count = board.changeCount
      defer { snapshot.restore(board, ifUnchanged: count) }
      guard matchesTarget(target), isSafe(target.element) else { return refuseReplacement() }
      postCommand(key: 9, pid: target.app.processIdentifier)
      // Hold the temporary clipboard until the receiver consumes the paste.
      // Abort on focus changes; never retry a paste whose outcome is ambiguous.
      var acknowledged = false
      for _ in 0..<30 {
        try? await Task.sleep(for: .milliseconds(20))
        guard sameFocus(app: target.app, element: target.element) else { break }
        if let range = selectedRange(target.element), range.location != target.range.location || range.length != target.range.length {
          acknowledged = true; break
        }
        if let current = selectedText(target.element), current != target.text { acknowledged = true; break }
      }
      if !acknowledged {
        self.target = nil
        notice = "The app did not confirm replacement. Check the source before trying again."
        return false
      }
    }
    self.target = nil
    notice = "Selection replaced."
    return true
  }

  private func refuseReplacement() -> Bool {
    target = nil
    notice = "The original selection can no longer be verified. Select the text again and invoke Enigma."
    return false
  }

  private func validate(_ target: Target) async -> Bool {
    guard matchesTarget(target), isSafe(target.element), isEditable(target.element) else { return false }
    let text = selectedText(target.element) ?? textForRange(target.element, range: target.range)
    let actual = if let text { text } else { await copySelection(app: target.app, element: target.element) }
    return actual == target.text && matchesTarget(target) && isSafe(target.element) && isEditable(target.element)
  }

  private func matchesTarget(_ target: Target) -> Bool {
    guard sameFocus(app: target.app, element: target.element),
          let window = element(target.element, kAXWindowAttribute), CFEqual(window, target.window),
          let range = selectedRange(target.element) else { return false }
    return SelectionReplacementPolicy.matches(original: target.range, current: range)
  }

  private func copySelection(app: NSRunningApplication, element: AXUIElement) async -> String? {
    guard sameFocus(app: app, element: element), isSafe(element), let snapshot = SelectionPasteboardSnapshot(.general) else { return nil }
    let interaction = SelectionInteractionGuard()
    defer { interaction.stop() }
    let board = NSPasteboard.general
    board.clearContents()
    let marker = NSPasteboard.PasteboardType("com.enigma.selection-copy")
    board.setString(UUID().uuidString, forType: marker)
    var ownedCount = board.changeCount
    defer { snapshot.restore(board, ifUnchanged: ownedCount) }
    postCommand(key: 8, pid: app.processIdentifier)
    for _ in 0..<30 {
      try? await Task.sleep(for: .milliseconds(20))
      guard !interaction.interrupted, sameFocus(app: app, element: element), isSafe(element) else { return nil }
      if board.changeCount != ownedCount {
        // A second writer must win: never restore over a newer user clipboard.
        guard board.changeCount == ownedCount + 1 else { return nil }
        ownedCount = board.changeCount
        return board.string(forType: .string)
      }
    }
    return nil
  }

  private func postCommand(key: CGKeyCode, pid: pid_t) {
    let source = CGEventSource(stateID: .privateState)
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
      event?.flags = .maskCommand
      event?.setIntegerValueField(.eventSourceUserData, value: SelectionInteractionGuard.eventMarker)
      event?.postToPid(pid)
    }
  }

  private func sameFocus(app: NSRunningApplication, element: AXUIElement) -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
          let focused = self.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute) else { return false }
    return CFEqual(focused, element)
  }

  private func isEditable(_ element: AXUIElement) -> Bool {
    if attribute(element, "AXEditable") as? Bool == true { return true }
    for key in [kAXSelectedTextAttribute, kAXValueAttribute] {
      var settable = DarwinBoolean(false)
      if AXUIElementIsAttributeSettable(element, key as CFString, &settable) == .success, settable.boolValue { return true }
    }
    return false
  }

  private func isSafe(_ element: AXUIElement) -> Bool {
    guard !IsSecureEventInputEnabled() else { return false }
    var current: AXUIElement? = element
    for _ in 0..<32 {
      guard let node = current, let role = attribute(node, kAXRoleAttribute) as? String else { return false }
      let subrole = attribute(node, kAXSubroleAttribute) as? String ?? ""
      if role.lowercased().contains("secure") || subrole.lowercased().contains("secure")
        || attribute(node, "AXProtectedContent") as? Bool == true { return false }
      if role == kAXApplicationRole { return true }
      current = self.element(node, kAXParentAttribute)
    }
    return false
  }

  private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
  }

  private func element(_ owner: AXUIElement, _ key: String) -> AXUIElement? {
    guard let value = attribute(owner, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
  }

  private func selectedText(_ element: AXUIElement) -> String? { attribute(element, kAXSelectedTextAttribute) as? String }

  private func selectedRange(_ element: AXUIElement) -> CFRange? {
    guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
    return range
  }

  private func textForRange(_ element: AXUIElement, range: CFRange) -> String? {
    var range = range
    guard range.length > 0, let parameter = AXValueCreate(.cfRange, &range) else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
      parameter, &value) == .success else { return nil }
    return value as? String
  }
}

/// Pure geometry shared by placement tests. Prefer a side with no selection overlap.
enum SelectionPanelPlacement {
  static func frame(size: NSSize, cursor: NSPoint, selection: NSRect?, visible: NSRect) -> NSRect {
    let size = NSSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
    let anchor = selection ?? NSRect(origin: cursor, size: .zero)
    let candidates = [
      NSPoint(x: anchor.maxX + 16, y: anchor.maxY - size.height),
      NSPoint(x: anchor.minX - size.width - 16, y: anchor.maxY - size.height),
      NSPoint(x: cursor.x - size.width / 2, y: anchor.minY - size.height - 16),
      NSPoint(x: cursor.x - size.width / 2, y: anchor.maxY + 16)
    ].map { point in
      NSRect(x: min(max(point.x, visible.minX), visible.maxX - size.width),
             y: min(max(point.y, visible.minY), visible.maxY - size.height), width: size.width, height: size.height)
    }
    return candidates.min { lhs, rhs in
      func score(_ rect: NSRect) -> CGFloat {
        let overlap = rect.intersection(anchor)
        return (overlap.isNull ? 0 : overlap.width * overlap.height) * 1000
          + hypot(rect.midX - cursor.x, rect.midY - cursor.y)
      }
      return score(lhs) < score(rhs)
    }!
  }
}

/// A replacement capability expires quickly and never accepts an insertion point.
enum SelectionReplacementPolicy {
  static func isFresh(capturedAt: Date, now: Date) -> Bool {
    let age = now.timeIntervalSince(capturedAt)
    return age >= 0 && age < 300
  }
  static func matches(original: CFRange, current: CFRange) -> Bool {
    original.location >= 0 && original.length > 0
      && original.location == current.location && original.length == current.length
  }
}

/// Watches event metadata only during an explicit capture/replacement transaction.
/// Synthetic copy/paste events are tagged so they do not cancel their own transaction.
@MainActor
private final class SelectionInteractionGuard {
  static let eventMarker: Int64 = 0x454E_4947
  private(set) var interrupted = false
  private var global: Any?
  private var local: Any?

  init() {
    let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
    global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.receive(event) }
    local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      self?.receive(event)
      return event
    }
  }

  func stop() {
    if let global { NSEvent.removeMonitor(global) }
    if let local { NSEvent.removeMonitor(local) }
    global = nil; local = nil
  }

  private func receive(_ event: NSEvent) {
    if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.eventMarker { interrupted = true }
  }
}

/// Browser canvas editors can expose an empty hidden input while DOM text is selected.
/// Copy is authoritative there. Native copy-line editors require a nonempty AX range.
enum SelectionCapturePolicy {
  static func allowsCopy(range: CFRange?, bundleID: String?) -> Bool {
    let bundleID = bundleID ?? ""
    let browsers: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari",
      "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "org.mozilla.firefox"]
    if let range { return range.length > 0 || browsers.contains(bundleID) }
    let lineEditors = ["com.microsoft.VSCode", "com.jetbrains.", "com.sublimetext.", "com.todesktop.230313mzl4w4u92"]
    return !lineEditors.contains { bundleID.hasPrefix($0) }
  }
}

/// macOS may suppress repeated trust prompts, so always provide a direct Settings route.
@MainActor
final class SelectionAccessibilityAccess: ObservableObject {
  static let shared = SelectionAccessibilityAccess()
  static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
  @Published private(set) var isGranted: Bool
  private let checkTrust: () -> Bool
  private let prompt: () -> Void
  private let openSettings: (URL) -> Void

  init(checkTrust: @escaping () -> Bool = { AXIsProcessTrusted() },
       prompt: @escaping () -> Void = {
         let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
         _ = AXIsProcessTrustedWithOptions(options)
       },
       openSettings: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
    self.checkTrust = checkTrust
    self.prompt = prompt
    self.openSettings = openSettings
    isGranted = checkTrust()
  }

  func refresh() { isGranted = checkTrust() }

  func requestAccess() {
    prompt()
    openSettings(Self.settingsURL)
    refresh()
  }
}
