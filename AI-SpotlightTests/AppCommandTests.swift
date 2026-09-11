import AppKit
@preconcurrency import Carbon
import XCTest
@testable import Enigma

final class AppCommandTests: XCTestCase {
  func testDoubleControlRequiresTwoShortTapsAndResetsAfterToggling() {
    var gesture = ControlDoubleTap()
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: .control, timestamp: 1))
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: [], timestamp: 1.08))
    XCTAssertFalse(gesture.flagsChanged(keyCode: 62, modifiers: .control, timestamp: 1.18))
    XCTAssertTrue(gesture.flagsChanged(keyCode: 62, modifiers: [], timestamp: 1.25))
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: .control, timestamp: 1.3))
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: [], timestamp: 1.35))
  }

  func testDoubleControlRejectsSlowTapsHoldsAndOtherModifiers() {
    var gesture = ControlDoubleTap()
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: .control, timestamp: 1))
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: [], timestamp: 2))
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: .control, timestamp: 2.1))
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: [], timestamp: 2.2))
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: .control, timestamp: 3))
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: [], timestamp: 3.1))
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: [.control, .shift], timestamp: 3.2))
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: [], timestamp: 3.3))
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: .control, timestamp: 3.4))
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: [], timestamp: 3.45))
    gesture.reset() // Typing, clicking, or leaving the panel cancels pending taps.
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: .control, timestamp: 3.5))
    XCTAssertFalse(gesture.flagsChanged(keyCode: 59, modifiers: [], timestamp: 3.55))
  }

  @MainActor
  func testDoubleControlWorksWhileEditingWithoutChangingDraft() throws {
    let field = NSTextField(string: "Keep my unsent text")
    let controller = SpotlightPanelController(glassAppearance: GlassAppearanceSettings(), contentView: field)
    controller.show()
    defer { controller.hide() }
    let window = try XCTUnwrap(field.window)
    XCTAssertTrue(window.makeFirstResponder(field))
    let delivered = expectation(forNotification: .sidebarToggleRequested, object: nil)
    for (time, flags) in [(1.0, NSEvent.ModifierFlags.control), (1.05, []), (1.15, .control), (1.2, [])] {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero,
        modifierFlags: flags, timestamp: time, windowNumber: window.windowNumber,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59))
      window.sendEvent(event)
    }
    wait(for: [delivered], timeout: 1)
    XCTAssertEqual(field.stringValue, "Keep my unsent text")
    XCTAssertTrue(controller.isVisible)
  }

  func testMenuCommandsHaveExpectedOrderAndTitles() {
    XCTAssertEqual(
      AppCommand.allCases.map(\.rawValue),
      ["Open", "New Chat", "Privacy Hide", "Settings", "Quit"]
    )
  }

  @MainActor
  func testStartupPreferencesPersistAndRecoverInvalidValues() {
    let name = "StartPreferencesTests-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = StartPreferences(defaults: defaults)
    XCTAssertEqual(preferences.mode, .auto)
    XCTAssertFalse(preferences.showsSidebar)
    for mode in ChatMode.allCases {
      preferences.mode = mode
      preferences.showsSidebar = true
      let restored = StartPreferences(defaults: defaults)
      XCTAssertEqual(restored.mode, mode)
      XCTAssertTrue(restored.showsSidebar)
    }
    defaults.set("removed-mode", forKey: StartPreferences.modeKey)
    XCTAssertEqual(StartPreferences(defaults: defaults).mode, .auto)
    preferences.showsSidebar = false
    XCTAssertFalse(StartPreferences(defaults: defaults).showsSidebar)
  }

  func testSavedGlassAppearanceIsRestored() {
    let suiteName = "GlassAppearanceSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = GlassAppearanceSettings(defaults: defaults)
    settings.isEnabled = false
    settings.clarity = 0.42
    settings.save()

    let restoredSettings = GlassAppearanceSettings(defaults: defaults)
    XCTAssertFalse(restoredSettings.isEnabled)
    XCTAssertEqual(restoredSettings.clarity, 0.42, accuracy: 0.001)
  }

  func testPanelShortcutsRequireOnlyTheCommandModifier() {
    XCTAssertEqual(
      PanelShortcut.resolve(characters: "n", modifiers: .command),
      .newChat
    )
    XCTAssertEqual(
      PanelShortcut.resolve(characters: "K", modifiers: .command),
      .modePalette
    )
    XCTAssertEqual(
      PanelShortcut.resolve(characters: ".", modifiers: .command),
      .stopStreaming
    )
    XCTAssertEqual(
      PanelShortcut.resolve(characters: "\t", modifiers: .control),
      .cycleRecentChat
    )
    XCTAssertEqual(
      PanelShortcut.resolve(characters: ",", modifiers: .command),
      .settings
    )
    XCTAssertNil(PanelShortcut.resolve(characters: ",", modifiers: [.command, .shift]))
    XCTAssertNil(
      PanelShortcut.resolve(characters: "n", modifiers: [.command, .shift])
    )
    XCTAssertEqual(
      PanelShortcut.resolve(characters: "n", modifiers: [.command, .capsLock]),
      .newChat
    )
    XCTAssertNil(PanelShortcut.resolve(characters: "n", modifiers: []))
  }

  func testHideInactiveToolsShortcutRequiresCommandShiftH() {
    XCTAssertEqual(PanelShortcut.resolve(characters: "H", modifiers: [.command, .shift]), .hideInactiveTools)
    XCTAssertEqual(PanelShortcut.resolve(characters: "h", modifiers: [.command, .shift, .capsLock]), .hideInactiveTools)
    XCTAssertNil(PanelShortcut.resolve(characters: "h", modifiers: .command))
    XCTAssertNil(PanelShortcut.resolve(characters: "h", modifiers: .shift))
    XCTAssertNil(PanelShortcut.resolve(characters: "h", modifiers: [.command, .option, .shift]))
  }

  @MainActor
  func testHideInactiveToolsShortcutWorksWhileTypingWithoutChangingDraft() throws {
    let field = NSTextField(string: "Keep my unsent text")
    let controller = SpotlightPanelController(glassAppearance: GlassAppearanceSettings(), contentView: field)
    controller.show()
    defer { controller.hide() }
    let window = try XCTUnwrap(field.window)
    XCTAssertTrue(window.makeFirstResponder(field))
    let delivered = expectation(forNotification: .hideInactiveToolsRequested, object: nil)
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber,
      context: nil, characters: "H", charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4))
    XCTAssertTrue(window.performKeyEquivalent(with: event))
    wait(for: [delivered], timeout: 1)
    XCTAssertEqual(field.stringValue, "Keep my unsent text")
    XCTAssertTrue(controller.isVisible)
  }

  func testGlobalHotKeysUseOptionSpaceAndOptionS() {
    XCTAssertEqual(GlobalHotKey.togglePanel.keyCode, UInt32(kVK_Space))
    XCTAssertEqual(GlobalHotKey.togglePanel.modifiers, UInt32(optionKey))
    XCTAssertEqual(GlobalHotKey.openSettings.keyCode, UInt32(kVK_ANSI_S))
    XCTAssertEqual(GlobalHotKey.openSettings.modifiers, UInt32(optionKey))
  }

  func testPanelSizeStoreUsesDefaultAndPersistsOnlySize() {
    let suiteName = "PanelSizeStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = PanelSizeStore(defaults: defaults)

    XCTAssertEqual(store.load(), PanelSizeStore.defaultSize)

    store.save(NSSize(width: 900, height: 610))

    XCTAssertEqual(store.load(), NSSize(width: 900, height: 610))
    let persistentDomain = defaults.persistentDomain(forName: suiteName) ?? [:]
    let persistedKeys = Set(persistentDomain.keys)
    XCTAssertEqual(
      persistedKeys,
      ["aiSpotlight.panel.width", "aiSpotlight.panel.height"]
    )
  }

  @MainActor
  func testWelcomeTemporarilyEnlargesPanelThroughTourWithoutSavingItsSize() async throws {
    let suite = "WelcomePanel-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PanelSizeStore(defaults: defaults)
    let normal = NSSize(width: 900, height: 610)
    store.save(normal)
    let setup = WelcomeSetup(defaults: defaults)
    let view = NSView()
    let controller = SpotlightPanelController(glassAppearance: GlassAppearanceSettings(defaults: defaults),
      sizeStore: store, contentView: view, welcomeSetup: setup)
    let window = try XCTUnwrap(view.window)
    defer { controller.hide() }
    func settleSizing() async {
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
    }
    setup.start(hasInstalledModels: false)
    await settleSizing()
    let visible = try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame
    let enlarged = PanelSizeStore.centeredFrame(size: NSSize(width: 1280, height: 860), in: visible).size
    XCTAssertEqual(window.frame.size, enlarged)
    controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
    XCTAssertEqual(store.load(), normal)
    setup.finish(takeTour: true)
    await settleSizing()
    XCTAssertEqual(window.frame.size, enlarged)
    setup.endTour()
    await settleSizing()
    XCTAssertEqual(window.frame.size, normal)
    setup.replay()
    await settleSizing()
    XCTAssertEqual(window.frame.size, enlarged)
    setup.finish(takeTour: false)
    await settleSizing()
    XCTAssertEqual(window.frame.size, normal)
    XCTAssertEqual(store.load(), normal)
  }

  @MainActor
  func testPanelRequestsCaptureExclusionWhileRemainingVisibleAndEditable() throws {
    let draft = NSTextField(string: "Visible only where capture exclusion is supported")
    let controller = SpotlightPanelController(
      glassAppearance: GlassAppearanceSettings(),
      contentView: draft
    )
    let window = try XCTUnwrap(draft.window)
    defer { controller.hide() }

    // Verify the flag is configured before the window's first presentation.
    XCTAssertEqual(window.sharingType, .none)
    controller.show()
    XCTAssertTrue(controller.isVisible)
    XCTAssertTrue(window.makeFirstResponder(draft))
    draft.stringValue = "The local panel remains usable"
    XCTAssertEqual(window.sharingType, .none)

    controller.hide()
    controller.show()
    XCTAssertTrue(controller.isVisible)
    XCTAssertEqual(window.sharingType, .none)
    XCTAssertEqual(draft.stringValue, "The local panel remains usable")
  }

  @MainActor
  func testSettingsWindowOpensAndReopensWithoutASwiftUIScene() throws {
    let controller = SettingsWindowController(contentView: NSView())
    let window = try XCTUnwrap(controller.window)
    defer { window.close() }

    XCTAssertEqual(window.sharingType, .none)
    XCTAssertTrue(window.titlebarAppearsTransparent)
    XCTAssertEqual(window.backgroundColor, NSColor(NatureGlass.forestTop))
    controller.showSettings()
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(window.isKeyWindow)
    window.performClose(nil)
    XCTAssertFalse(window.isVisible)

    controller.showSettings()
    XCTAssertTrue(controller.window === window)
    XCTAssertEqual(window.sharingType, .none)
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(window.isKeyWindow)
  }

  @MainActor
  func testOpeningAdvancedSettingsPreservesChatVisibilityAndDraft() throws {
    let draft = NSTextField(string: "Keep this unsent message")
    let panel = SpotlightPanelController(
      glassAppearance: GlassAppearanceSettings(),
      contentView: draft
    )
    let settings = SettingsWindowController(contentView: NSView())
    let window = try XCTUnwrap(settings.window)
    let delegate = ApplicationDelegate(panelController: panel, settingsWindowController: settings)
    defer {
      window.close()
      panel.hide()
    }

    panel.show()
    delegate.openSettings()
    XCTAssertTrue(panel.isVisible)
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(window.isKeyWindow)
    XCTAssertEqual(window.level, .floating)
    XCTAssertEqual(draft.stringValue, "Keep this unsent message")

    window.performClose(nil)
    XCTAssertTrue(panel.isVisible)
    delegate.openSettings()
    XCTAssertTrue(panel.isVisible)
    XCTAssertTrue(window.isVisible)
    XCTAssertEqual(draft.stringValue, "Keep this unsent message")

    panel.hide()
    delegate.openSettings()
    XCTAssertFalse(panel.isVisible, "Opening Settings must also respect an already hidden chat.")
  }

  func testPanelFrameIsCenteredAndConstrainedToDisplay() {
    let visibleFrame = NSRect(x: 100, y: 50, width: 700, height: 500)

    let frame = PanelSizeStore.centeredFrame(
      size: NSSize(width: 760, height: 520),
      in: visibleFrame
    )

    XCTAssertEqual(frame, visibleFrame)
  }
}
