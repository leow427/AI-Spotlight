import AppKit
import SwiftUI

struct PanelSizeStore {
  static let defaultSize = NSSize(width: 760, height: 520)
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

  private(set) var isCapturingScreen = false
  private var captureHiddenWindows: [NSWindow] = []
  private var capturePanelAlpha: CGFloat?
  private var capturePanelIgnoredMouseEvents: Bool?
  var isVisible: Bool { panel.isVisible && !isCapturingScreen }

  init(
    glassAppearance: GlassAppearanceSettings,
    sizeStore: PanelSizeStore = PanelSizeStore(),
    contentView: NSView? = nil
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
    panel.title = "AI Spotlight"
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

    panel.onHide = { [weak self] in
      self?.hide()
    }
    panel.onShortcut = { [weak self] shortcut in
      self?.perform(shortcut)
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
    // Keeping the panel ordered preserves SwiftUI's compositor surface. At zero
    // alpha it contributes no screenshot pixels, and click-through lets the
    // system selection tool receive every event.
    capturePanelAlpha = panel.alphaValue
    capturePanelIgnoredMouseEvents = panel.ignoresMouseEvents
    panel.ignoresMouseEvents = true
    panel.alphaValue = 0
  }

  @objc private func endScreenCapture() {
    guard isCapturingScreen else { return }
    captureHiddenWindows.forEach { $0.orderFrontRegardless() }
    captureHiddenWindows = []
    panel.ignoresMouseEvents = capturePanelIgnoredMouseEvents ?? false
    panel.alphaValue = capturePanelAlpha ?? 1
    capturePanelAlpha = nil
    capturePanelIgnoredMouseEvents = nil
    isCapturingScreen = false
    panel.orderFrontRegardless()
    panel.makeKey()
    panel.contentView?.needsDisplay = true
    panel.displayIfNeeded()
    panel.invalidateShadow()
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
    sizeStore.save(panel.frame.size)
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
    }
  }
}

private final class SpotlightPanel: NSPanel {
  var onHide: (() -> Void)?
  var onShortcut: ((PanelShortcut) -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func keyDown(with event: NSEvent) {
    guard event.keyCode != 53 else {
      onHide?()
      return
    }
    super.keyDown(with: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.keyCode == 53 {
      onHide?()
      return true
    }
    if let shortcut = PanelShortcut.resolve(
      characters: event.charactersIgnoringModifiers,
      modifiers: event.modifierFlags
    ) {
      onShortcut?(shortcut)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}
