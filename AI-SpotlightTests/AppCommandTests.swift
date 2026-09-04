import AppKit
@preconcurrency import Carbon
import XCTest
@testable import PrimaryAgent

final class AppCommandTests: XCTestCase {
  func testMenuCommandsHaveExpectedOrderAndTitles() {
    XCTAssertEqual(
      AppCommand.allCases.map(\.rawValue),
      ["Open", "New Chat", "Privacy Hide", "Settings", "Quit"]
    )
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
