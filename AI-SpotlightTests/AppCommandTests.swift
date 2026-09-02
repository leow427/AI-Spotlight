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
}
