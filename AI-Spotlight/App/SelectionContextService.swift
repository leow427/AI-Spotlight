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
  private var continuity: SelectionSourceContinuity?

  private struct Target {
    let contextID: UUID
    let app: NSRunningApplication
    let element: AXUIElement
    let window: AXUIElement
    let range: CFRange?
    let document: AXUIElement?
    let documentURL: String?
    let text: String
    let capturedAt: Date
  }

  var canReplace: Bool { target != nil && continuity?.isIntact == true && !isWorking }
  func discardTarget() {
    continuity?.stop(); continuity = nil
    target = nil; capturedBounds = nil; notice = nil
  }

  private func revokeTarget() {
    continuity?.stop(); continuity = nil
    target = nil
  }

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
    let document = webDocument(element)
    var copiedSelection = false
    var text = selectedText(element)
    // Some editors expose a text range but not AXSelectedText.
    if text == nil, let range { text = textForRange(element, range: range) }
    if text == nil || text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true || (document != nil && (range?.length ?? 0) == 0) {
      guard SelectionCapturePolicy.allowsCopy(range: range, bundleID: app.bundleIdentifier) else { return nil }
      text = await copySelection(app: app, element: element)
      copiedSelection = text?.isEmpty == false
    }
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !interaction.interrupted, sameFocus(app: app, element: element), isSafe(element) else { return nil }
    guard text.utf8.count <= 256_000 else {
      notice = "The selection is too large to attach. Select a smaller passage and try again."
      return nil
    }
    if let range, range.length > 0 { capturedBounds = bounds(element: element, range: range) }
    let context = ConversationContext(sourceName: app.localizedName ?? "Application", text: text)
    let documentURL = document.flatMap { urlAttribute($0) }
    let verifiedRange = SelectionReplacementPolicy.rangeForReplacement(range, usedCopy: copiedSelection, hasWebDocument: document != nil)
    let usesCopyAnchor = SelectionReplacementPolicy.allowsCopyAnchor(hasRange: verifiedRange != nil,
      copiedText: copiedSelection ? text : nil, hasDocument: document != nil, documentURL: documentURL,
      editable: isEditable(element))
    // Canvas editors expose a hidden editable input with no document range.
    // A copy-backed anchor requires an identified web document and field, and
    // remains valid only while the source receives no user interaction.
    if isEditable(element), let window = self.element(element, kAXWindowAttribute),
       verifiedRange != nil || usesCopyAnchor {
      target = Target(contextID: context.id, app: app, element: element, window: window,
                      range: verifiedRange, document: document, documentURL: documentURL,
                      text: text, capturedAt: .now)
      continuity = SelectionSourceContinuity(sourcePID: app.processIdentifier)
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
          !text.isEmpty, text.utf8.count <= 256_000 else {
      notice = "Replacement is unavailable. Select the text again and invoke Enigma."
      return false
    }
    isWorking = true
    defer { isWorking = false }
    let interaction = SelectionInteractionGuard()
    defer { interaction.stop() }
    guard continuity?.isIntact == true, SelectionReplacementPolicy.isFresh(capturedAt: target.capturedAt, now: .now), !target.app.isTerminated,
          AXIsProcessTrusted(), isSafe(target.element) else { return refuseReplacement() }
    NotificationCenter.default.post(name: .selectionReplacementBegan, object: nil)
    defer { NotificationCenter.default.post(name: .selectionReplacementEnded, object: nil) }
    target.app.activate(options: [])
    for _ in 0..<15 {
      if sameFocus(app: target.app, element: target.element) { break }
      try? await Task.sleep(for: .milliseconds(20))
    }
    guard await validate(target), !interaction.interrupted else { return refuseReplacement() }
    let originalValue = attribute(target.element, kAXValueAttribute) as? String
    var settable = DarwinBoolean(false)
    // Web accessibility setters may acknowledge a write without dispatching an
    // editor input event. Use the browser's normal paste path for web content.
    if target.range != nil, target.document == nil, AXUIElementIsAttributeSettable(target.element, kAXSelectedTextAttribute as CFString, &settable) == .success,
       settable.boolValue {
      // A failed write can be ambiguous; never follow it with a second mutation.
      guard AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
        return refuseReplacement()
      }
      guard await confirmReplacement(target, replacement: text, originalValue: originalValue) else {
        return unconfirmedReplacement()
      }
    } else {
      let board = NSPasteboard.general
      guard let snapshot = SelectionPasteboardSnapshot(board), await validate(target), !interaction.interrupted else { return refuseReplacement() }
      board.clearContents()
      board.setString(text, forType: .string)
      board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
      board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
      let count = board.changeCount
      defer { snapshot.restore(board, ifUnchanged: count) }
      guard matchesTarget(target), isSafe(target.element), !interaction.interrupted else { return refuseReplacement() }
      postCommand(key: 9, pid: target.app.processIdentifier)
      // Canvas editors do not expose the resulting document text. Keep the
      // clipboard available for the bounded paste window and report dispatch
      // honestly; never retry an unobservable mutation.
      if target.range == nil {
        for _ in 0..<30 {
          try? await Task.sleep(for: .milliseconds(20))
          if interaction.interrupted || !sameFocus(app: target.app, element: target.element) { break }
        }
        revokeTarget()
        notice = "Replacement sent to \(target.app.localizedName ?? "the source app"). Check the document to confirm."
        return true
      }
      // Keep the clipboard until the receiver exposes the expected text.
      guard await confirmReplacement(target, replacement: text, originalValue: originalValue) else {
        return unconfirmedReplacement()
      }
    }
    revokeTarget()
    notice = "Selection replaced."
    return true
  }

  private func confirmReplacement(_ target: Target, replacement: String, originalValue: String?) async -> Bool {
    guard let range = target.range else { return false }
    for _ in 0..<30 {
      try? await Task.sleep(for: .milliseconds(20))
      guard sameFocus(app: target.app, element: target.element), isSafe(target.element) else { return false }
      let currentValue = attribute(target.element, kAXValueAttribute) as? String
      if SelectionReplacementPolicy.confirms(originalValue: originalValue, currentValue: currentValue,
        range: range, originalSelection: target.text, replacement: replacement) { return true }
      let replacedRange = CFRange(location: range.location, length: (replacement as NSString).length)
      if textForRange(target.element, range: replacedRange) == replacement,
         selectedRange(target.element).map({ $0.location == replacedRange.location + replacedRange.length && $0.length == 0 }) == true {
        return true
      }
    }
    return false
  }

  private func unconfirmedReplacement() -> Bool {
    revokeTarget()
    notice = "The app did not confirm replacement. Check the source before trying again."
    return false
  }

  private func refuseReplacement() -> Bool {
    revokeTarget()
    notice = "The original selection can no longer be verified. Select the text again and invoke Enigma."
    return false
  }

  private func validate(_ target: Target) async -> Bool {
    guard matchesTarget(target), isSafe(target.element), isEditable(target.element) else { return false }
    let actual: String?
    if let range = target.range {
      let exposed = selectedText(target.element) ?? textForRange(target.element, range: range)
      actual = if let exposed, !exposed.isEmpty { exposed }
        else { await copySelection(app: target.app, element: target.element) }
    } else {
      // Do not trust the canvas editor's hidden textarea value/range. Copy the
      // still-highlighted document text immediately before every paste.
      return await SelectionCopyVerification.matches(expected: target.text,
        isTargetValid: { self.matchesTarget(target) && self.isSafe(target.element) && self.isEditable(target.element) },
        copy: { await self.copySelection(app: target.app, element: target.element) })
    }
    return actual == target.text && matchesTarget(target) && isSafe(target.element) && isEditable(target.element)
  }

  private func matchesTarget(_ target: Target) -> Bool {
    guard continuity?.isIntact == true, sameFocus(app: target.app, element: target.element),
          let window = element(target.element, kAXWindowAttribute), CFEqual(window, target.window) else { return false }
    if let document = target.document {
      guard let currentDocument = webDocument(target.element), CFEqual(document, currentDocument),
            urlAttribute(currentDocument) == target.documentURL else { return false }
    }
    if let original = target.range {
      guard let current = selectedRange(target.element) else { return false }
      return SelectionReplacementPolicy.matches(original: original, current: current)
    }
    return target.document != nil && target.documentURL != nil
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

  private func urlAttribute(_ element: AXUIElement) -> String? {
    if let url = attribute(element, kAXURLAttribute) as? URL { return url.absoluteString }
    if let url = attribute(element, kAXURLAttribute) as? String, !url.isEmpty { return url }
    return nil
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
  static func rangeForReplacement(_ range: CFRange?, usedCopy: Bool, hasWebDocument: Bool) -> CFRange? {
    // A copied browser selection can come from a canvas while its hidden input
    // exposes a nonempty placeholder range. That range is not a document anchor.
    guard let range, range.length > 0, !(usedCopy && hasWebDocument) else { return nil }
    return range
  }

  static func allowsCopyAnchor(hasRange: Bool, copiedText: String?, hasDocument: Bool,
                               documentURL: String?, editable: Bool) -> Bool {
    guard !hasRange, editable, hasDocument, let copiedText,
          !copiedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let documentURL, let url = URL(string: documentURL),
          ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return false }
    return true
  }

  static func confirms(originalValue: String?, currentValue: String?, range: CFRange,
                       originalSelection: String, replacement: String) -> Bool {
    guard let originalValue, let currentValue, range.location >= 0, range.length > 0 else { return false }
    let original = originalValue as NSString
    guard range.location <= original.length, range.length <= original.length - range.location,
          original.substring(with: NSRange(location: range.location, length: range.length)) == originalSelection else { return false }
    return currentValue == original.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: replacement)
  }

  static func isFresh(capturedAt: Date, now: Date) -> Bool {
    let age = now.timeIntervalSince(capturedAt)
    return age >= 0 && age < 300
  }
  static func matches(original: CFRange, current: CFRange) -> Bool {
    original.location >= 0 && original.length > 0
      && original.location == current.location && original.length == current.length
  }
}

/// Revalidate around the asynchronous copy: matching text alone never grants a
/// write into a changed field, document, or occurrence of the same words.
@MainActor
enum SelectionCopyVerification {
  static func matches(expected: String, isTargetValid: () -> Bool, copy: () async -> String?) async -> Bool {
    guard !expected.isEmpty, isTargetValid() else { return false }
    guard let copied = await copy(), copied == expected else { return false }
    return isTargetValid()
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

/// Retains only an invalidation bit while a replacement capability exists.
/// Enigma's own typing is local; external interaction in the source invalidates
/// the capability even if a different occurrence of identical text is selected.
@MainActor
private final class SelectionSourceContinuity {
  private(set) var isIntact = true
  private var monitor: Any?
  private var expiry: Task<Void, Never>?

  init(sourcePID: pid_t) {
    let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
    monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
      guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != SelectionInteractionGuard.eventMarker,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return }
      self?.isIntact = false
      self?.stop()
    }
    expiry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(300))
      guard !Task.isCancelled else { return }
      self?.isIntact = false
      self?.stop()
    }
  }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    expiry?.cancel(); expiry = nil
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
