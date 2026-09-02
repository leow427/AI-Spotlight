import XCTest
@testable import PrimaryAgent

final class AppCommandTests: XCTestCase {
  func testMenuCommandsHaveExpectedOrderAndTitles() {
    XCTAssertEqual(
      AppCommand.allCases.map(\.rawValue),
      ["Open", "New Chat", "Privacy Hide", "Settings", "Quit"]
    )
  }
}
