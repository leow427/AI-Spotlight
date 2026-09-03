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
    XCTAssertNil(
      PanelShortcut.resolve(characters: "n", modifiers: [.command, .shift])
    )
    XCTAssertEqual(
      PanelShortcut.resolve(characters: "n", modifiers: [.command, .capsLock]),
      .newChat
    )
    XCTAssertNil(PanelShortcut.resolve(characters: "n", modifiers: []))
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

  func testPanelFrameIsCenteredAndConstrainedToDisplay() {
    let visibleFrame = NSRect(x: 100, y: 50, width: 700, height: 500)

    let frame = PanelSizeStore.centeredFrame(
      size: NSSize(width: 760, height: 520),
      in: visibleFrame
    )

    XCTAssertEqual(frame, visibleFrame)
  }
}
