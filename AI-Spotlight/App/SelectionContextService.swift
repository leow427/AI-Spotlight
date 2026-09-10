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
    // Retaining the running application also lets us detect its termination;
    // a later application that reuses its PID must not receive this paste.
    let app: NSRunningApplication
    var pid: pid_t { app.processIdentifier }
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
    let mayCapture = {
      !Task.isCancelled && !interaction.interrupted && !IsSecureEventInputEnabled()
        && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }
    guard let element = await SelectionCaptureRetry.first(mayContinue: mayCapture,
      read: { self.element(application, kAXFocusedUIElementAttribute) }), isSafe(element) else { return nil }
    let document = webDocument(element)
    let selection = await SelectionCaptureRetry.first(mayContinue: {
      mayCapture() && self.sameFocus(app: app, element: element) && self.isSafe(element)
    }, read: { () -> (CFRange?, String)? in
      let range = self.selectedRange(element)
      let text = self.selectedText(element) ?? range.flatMap { self.textForRange(element, range: $0) }
      guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      return (range, text)
    })
    let range = selection?.0 ?? selectedRange(element)
    var text = selection?.1
    if text == nil || text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true || (document != nil && (range?.length ?? 0) == 0) {
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
    target = Target(contextID: context.id, app: app)

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

  /// Paste once into the remembered app's current selection, without restoring
  /// or inspecting the originally captured field, document, text, or range.
  func replace(with text: String, contextID: UUID) async -> Bool {
    guard !isWorking, let target, target.contextID == contextID else {
      notice = "Replacement is unavailable. Select text and invoke Enigma again."
      return false
    }
    isWorking = true
    defer { isWorking = false }
    NotificationCenter.default.post(name: .selectionReplacementBegan, object: nil)
    defer { NotificationCenter.default.post(name: .selectionReplacementEnded, object: nil) }
    let outcome = await SelectionPasteTransaction.perform(text: text, pid: target.pid, board: .general,
      isAvailable: { AXIsProcessTrusted() && !target.app.isTerminated && !IsSecureEventInputEnabled() },
      activate: {
        guard target.app.activate(options: []) else { return false }
        for _ in 0..<30 {
          if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid { return true }
          try? await Task.sleep(for: .milliseconds(20))
        }
        return false
      },
      isSafeToPaste: {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return false }
        let application = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let focused = self.element(application, kAXFocusedUIElementAttribute) else { return false }
        // Inspect only the current field's password/protected status, not its identity.
        return self.isSafe(focused)
      },
      postPaste: { self.postCommand(key: 9, pid: $0) },
      settle: { try? await Task.sleep(for: .milliseconds(600)) })
    switch outcome {
    case .sent:
      self.target = nil // No automatic or accidental second attempt at an ambiguous paste.
      notice = "Replacement sent to \(target.app.localizedName ?? "the source app")."
      return true
    case .unavailable:
      notice = "Replacement could not be sent. Check Accessibility permission and that the source app is open. Password fields cannot receive replacement."
    case .clipboardUnavailable:
      notice = "The clipboard could not be preserved. Replacement was not sent."
    case .eventUnavailable:
      notice = "The paste could not be sent to the source app."
    }
    return false
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
    for _ in 0..<2 {
      guard !Task.isCancelled, !interaction.interrupted, sameFocus(app: app, element: element), isSafe(element),
            board.changeCount == ownedCount else { return nil }
      guard postCommand(key: 8, pid: app.processIdentifier) else { return nil }
      for _ in 0..<20 {
        try? await Task.sleep(for: .milliseconds(20))
        guard !Task.isCancelled, !interaction.interrupted, sameFocus(app: app, element: element), isSafe(element) else { return nil }
        if board.changeCount != ownedCount {
          // Never retry after any clipboard write, or restore over a newer copy.
          guard board.changeCount == ownedCount + 1 else { return nil }
          ownedCount = board.changeCount
          return board.string(forType: .string)
        }
      }
      // A single retry handles an editor that was not ready for the first Cmd+C.
      // The source is still focused and the marker has not been consumed.
    }
    return nil
  }

  @discardableResult
  private func postCommand(key: CGKeyCode, pid: pid_t) -> Bool {
    let source = CGEventSource(stateID: .privateState)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
    for event in [down, up] {
      event.flags = .maskCommand
      event.setIntegerValueField(.eventSourceUserData, value: SelectionInteractionGuard.eventMarker)
      event.postToPid(pid)
    }
    return true
  }

  private func sameFocus(app: NSRunningApplication, element: AXUIElement) -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
          let focused = self.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute) else { return false }
    return CFEqual(focused, element)
  }

  private func webDocument(_ element: AXUIElement) -> AXUIElement? {
    var current: AXUIElement? = element
    var document: AXUIElement?
    for _ in 0..<32 {
      guard let node = current else { break }
      if attribute(node, kAXRoleAttribute) as? String == "AXWebArea" { document = node }
      current = self.element(node, kAXParentAttribute)
    }
    // Keep the outer document identity, not an editor's about:blank iframe.
    return document
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

/// Bounded readiness retries occur only inside a deliberate invocation.
@MainActor
enum SelectionCaptureRetry {
  static func first<Value>(mayContinue: () -> Bool, read: () -> Value?,
                           wait: () async -> Void = { try? await Task.sleep(for: .milliseconds(30)) }) async -> Value? {
    for attempt in 0..<3 {
      guard !Task.isCancelled, mayContinue() else { return nil }
      if let value = read() { return value }
      if attempt < 2 { await wait() }
    }
    return nil
  }
}

/// One process-targeted paste with a lossless, ownership-aware clipboard restore.
/// The injectable operations keep transaction ordering and failure paths testable
/// without sending keyboard events to real applications during unit tests.
@MainActor
enum SelectionPasteTransaction {
  enum Outcome: Equatable { case sent, unavailable, clipboardUnavailable, eventUnavailable }

  static func perform(text: String, pid: pid_t, board: NSPasteboard,
                      isAvailable: () -> Bool, activate: () async -> Bool,
                      isSafeToPaste: () -> Bool, postPaste: (pid_t) -> Bool,
                      settle: () async -> Void) async -> Outcome {
    guard !Task.isCancelled, !text.isEmpty, text.utf8.count <= 256_000, isAvailable(), await activate(),
          !Task.isCancelled, isAvailable(), isSafeToPaste() else { return .unavailable }
    guard let snapshot = SelectionPasteboardSnapshot(board) else { return .clipboardUnavailable }
    board.clearContents()
    var ownedCount = board.changeCount
    defer { snapshot.restore(board, ifUnchanged: ownedCount) }
    let written = board.setString(text, forType: .string)
      && board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
      && board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
    ownedCount = board.changeCount
    guard written else { return .clipboardUnavailable }
    guard postPaste(pid) else { return .eventUnavailable }
    await settle()
    return .sent // Dispatch is not proof that an external editor accepted the paste.
  }
}

/// Watches event metadata only during an explicit capture transaction.
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
  static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
    ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Enigma"
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
