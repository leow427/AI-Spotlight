import AppKit
import Combine
import SwiftUI

struct PanelSizeStore {
  static let defaultSize = NSSize(width: 1200, height: 780)
  static let minimumSize = NSSize(width: 640, height: 420)

  private enum Key {
    static let width = "aiSpotlight.panel.width"
    static let height = "aiSpotlight.panel.height"
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> NSSize {
    let width = defaults.double(forKey: Key.width)
    let height = defaults.double(forKey: Key.height)
    guard width.isFinite,
          height.isFinite,
          width >= Self.minimumSize.width,
          height >= Self.minimumSize.height else {
      return Self.defaultSize
    }
    return NSSize(width: width, height: height)
  }

  func save(_ size: NSSize) {
    guard size.width.isFinite, size.height.isFinite else { return }
    defaults.set(max(size.width, Self.minimumSize.width), forKey: Key.width)
    defaults.set(max(size.height, Self.minimumSize.height), forKey: Key.height)
  }

  static func centeredFrame(size: NSSize, in visibleFrame: NSRect) -> NSRect {
    let fittedSize = NSSize(
      width: min(size.width, visibleFrame.width),
      height: min(size.height, visibleFrame.height)
    )
    return NSRect(
      x: visibleFrame.midX - fittedSize.width / 2,
      y: visibleFrame.midY - fittedSize.height / 2,
      width: fittedSize.width,
      height: fittedSize.height
    )
  }
}

@MainActor
final class SpotlightPanelController: NSObject, NSWindowDelegate {
  private let panel: SpotlightPanel
  private let sizeStore: PanelSizeStore
  private var welcomeObservation: AnyCancellable?
  private var normalSize: NSSize?

  private(set) var isCapturingScreen = false
  private var captureHiddenWindows: [NSWindow] = []
  var isVisible: Bool { panel.isVisible && !isCapturingScreen }

  init(
    glassAppearance: GlassAppearanceSettings,
    sizeStore: PanelSizeStore = PanelSizeStore(),
    contentView: NSView? = nil,
    welcomeSetup: WelcomeSetup? = nil
  ) {
    self.sizeStore = sizeStore
    panel = SpotlightPanel(
      contentRect: NSRect(origin: .zero, size: sizeStore.load()),
      styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    super.init()

    panel.delegate = self
    panel.title = "Enigma"
    // Best-effort exclusion for capture clients that honor the legacy window flag.
    // ScreenCaptureKit may still include this window; keep it visible locally.
    panel.sharingType = .none
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.animationBehavior = .utilityWindow
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.minSize = PanelSizeStore.minimumSize
    panel.contentView = contentView ?? NSHostingView(
      rootView: AppShellView(glassAppearance: glassAppearance)
    )

    NotificationCenter.default.addObserver(self, selector: #selector(beginScreenCapture), name: .screenCaptureBegan, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(endScreenCapture), name: .screenCaptureEnded, object: nil)

    NotificationCenter.default.addObserver(self, selector: #selector(beginSelectionReplacement), name: .selectionReplacementBegan, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(endSelectionReplacement), name: .selectionReplacementEnded, object: nil)
    if let welcomeSetup {
      welcomeObservation = welcomeSetup.$isPresented.combineLatest(welcomeSetup.$tour)
        .map { $0 || $1 != nil }.removeDuplicates()
        .sink { [weak self] active in self?.setWelcomeSizing(active) }
    }
    panel.onHide = { [weak self] in
      self?.hide()
    }
    panel.onShortcut = { [weak self] shortcut in
      self?.perform(shortcut)
    }
  }

  @objc private func beginSelectionReplacement() {
    // A nonactivating panel can own keyboard focus while the source is already
    // frontmost. Activating that app alone does not release the panel's focus.
    panel.orderOut(nil)
  }

  @objc private func endSelectionReplacement() {
    panel.orderFrontRegardless()
    panel.makeKey()
    NotificationCenter.default.post(name: .panelPresented, object: nil)
  }

  private var selectionInvocation: Task<Void, Never>?

  func summonSelectionContext() {
    guard !isCapturingScreen, selectionInvocation == nil else { return }
    let cursor = NSEvent.mouseLocation
    let visible = (NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
    selectionInvocation = Task { [weak self] in
      let service = SelectionContextService.shared
      let context = await service.capture()
      guard let self else { return }
      defer { self.selectionInvocation = nil }
      guard !self.isCapturingScreen else { service.discardTarget(); return }
      // The hosted view is already installed, and handles reset before focus changes.
      NotificationCenter.default.post(name: .selectionContextRequested, object: context)
      if let visible {
        self.panel.setFrame(SelectionPanelPlacement.frame(size: NSSize(width: 720, height: 540),
          cursor: cursor, selection: service.selectionBounds(), visible: visible), display: true)
      }
      self.panel.orderFrontRegardless()
      self.panel.makeKey()
      NotificationCenter.default.post(name: .panelPresented, object: nil)
    }
  }

  func show() {
    guard !isCapturingScreen else { return }
    centerOnActiveDisplay()
    panel.orderFrontRegardless()
    panel.makeKey()
    NotificationCenter.default.post(name: .panelPresented, object: nil)
  }

  @objc private func beginScreenCapture() {
    guard !isCapturingScreen else { return }
    isCapturingScreen = true
    captureHiddenWindows = NSApp.windows.filter { $0 !== panel && $0.isVisible }
    captureHiddenWindows.forEach { $0.orderOut(nil) }
    // Removing the panel from the window server avoids capturing it and gives
    // SwiftUI a fresh compositor surface when the panel is restored. Keeping an
    // ordered window at zero alpha can leave that surface transparent after the
    // system screenshot picker disconnects on macOS 26.
    panel.orderOut(nil)
  }

  @objc private func endScreenCapture() {
    guard isCapturingScreen else { return }
    captureHiddenWindows.forEach { $0.orderFrontRegardless() }
    captureHiddenWindows = []
    isCapturingScreen = false
    panel.orderFrontRegardless()
    panel.makeKey()
    panel.contentView?.needsLayout = true
    panel.contentView?.needsDisplay = true
    NotificationCenter.default.post(name: .panelPresented, object: nil)
  }

  func hide() {
    panel.orderOut(nil)
    NotificationCenter.default.post(name: .panelHidden, object: nil)
  }

  func toggle() {
    guard !isCapturingScreen else { return }
    panel.isVisible ? hide() : show()
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    guard normalSize == nil else { return }
    sizeStore.save(panel.frame.size)
  }

  private func setWelcomeSizing(_ active: Bool) {
    let size: NSSize
    if active {
      guard normalSize == nil else { return }
      normalSize = panel.frame.size
      size = NSSize(width: max(1280, panel.frame.width), height: max(860, panel.frame.height))
    } else {
      guard let previous = normalSize else { return }
      size = previous
      normalSize = nil
    }
    let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    let frame = visible.map { PanelSizeStore.centeredFrame(size: size, in: $0) }
      ?? NSRect(origin: panel.frame.origin, size: size)
    panel.setFrame(frame, display: true)
  }

  private func centerOnActiveDisplay() {
    let mouseLocation = NSEvent.mouseLocation
    let activeScreen = NSScreen.screens.first { screen in
      NSMouseInRect(mouseLocation, screen.frame, false)
    } ?? NSScreen.main
    guard let visibleFrame = activeScreen?.visibleFrame else { return }

    let centeredFrame = PanelSizeStore.centeredFrame(
      size: panel.frame.size,
      in: visibleFrame
    )
    panel.setFrame(centeredFrame, display: true)
  }

  private func perform(_ shortcut: PanelShortcut) {
    switch shortcut {
    case .toggleSidebar:
      NotificationCenter.default.post(name: .sidebarToggleRequested, object: nil)
    case .fileMode:
      NotificationCenter.default.post(name: .fileModeRequested, object: nil)
    case .newChat:
      NotificationCenter.default.post(name: .newChatRequested, object: nil)
    case .modePalette:
      NotificationCenter.default.post(name: .modePaletteRequested, object: nil)
    case .stopStreaming:
      NotificationCenter.default.post(name: .stopStreamingRequested, object: nil)
    case .cycleRecentChat:
      NotificationCenter.default.post(name: .recentChatCycleRequested, object: nil)
    case .settings:
      NotificationCenter.default.post(name: .settingsRequested, object: nil)
    case .hideInactiveTools:
      NotificationCenter.default.post(name: .hideInactiveToolsRequested, object: nil)
    }
  }
}

private final class SpotlightPanel: NSPanel {
  private var controlDoubleTap = ControlDoubleTap()
  var onHide: (() -> Void)?
  var onShortcut: ((PanelShortcut) -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .flagsChanged {
      if isKeyWindow && controlDoubleTap.flagsChanged(keyCode: event.keyCode, modifiers: event.modifierFlags, timestamp: event.timestamp) {
        onShortcut?(.toggleSidebar)
      }
    } else if [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
      controlDoubleTap.reset()
    }
    super.sendEvent(event)
  }

  override func resignKey() {
    controlDoubleTap.reset()
    super.resignKey()
  }

  override func keyDown(with event: NSEvent) {
    guard event.keyCode != 53 else {
      onHide?()
      return
    }
    super.keyDown(with: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    controlDoubleTap.reset()
    if event.keyCode == 53 {
      if let editor = firstResponder as? SlashCommandTextView, editor.completion?.dismiss() == true { return true }
      onHide?()
      return true
    }
    if let shortcut = PanelShortcut.resolve(
      characters: event.keyCode == 3 && event.modifierFlags.intersection([.shift, .option, .command, .control]) == [.shift, .option]
        ? "f" : event.charactersIgnoringModifiers,
      modifiers: event.modifierFlags
    ) {
      onShortcut?(shortcut)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}
