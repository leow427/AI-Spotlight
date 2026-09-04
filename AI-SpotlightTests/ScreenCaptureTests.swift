import AppKit
import XCTest
@testable import PrimaryAgent

@MainActor
final class ScreenCaptureTests: XCTestCase {
  func testCommandParsing() {
    XCTAssertEqual(ScreenCommand.remainder(in: "/screen what is the answer?"), "what is the answer?")
    XCTAssertEqual(ScreenCommand.remainder(in: " /SCREEN\ncode? "), "code?")
    XCTAssertEqual(ScreenCommand.remainder(in: "/screen"), "")
    XCTAssertNil(ScreenCommand.remainder(in: "/screenshots"))
    XCTAssertNil(ScreenCommand.remainder(in: "explain /screen"))
    XCTAssertNil(ScreenCommand.remainder(in: "`/screen`"))
  }

  func testPermissionFailureDoesNotHideThePanel() async {
    let probe = CaptureNotificationProbe()
    NotificationCenter.default.addObserver(probe, selector: #selector(CaptureNotificationProbe.began),
      name: .screenCaptureBegan, object: nil)
    NotificationCenter.default.addObserver(probe, selector: #selector(CaptureNotificationProbe.ended),
      name: .screenCaptureEnded, object: nil)
    defer { NotificationCenter.default.removeObserver(probe) }
    let screen = ScreenComposerCoordinator(captureService: PermissionFailingCapture())
    screen.draft = "keep this question"
    _ = await screen.capture()
    XCTAssertEqual(probe.beginCount, 0)
    XCTAssertEqual(probe.endCount, 0)
    XCTAssertEqual(screen.draft, "keep this question")
    XCTAssertNotNil(screen.error)
  }

  func testCancellationPreservesDraftAndPreviousAttachment() async throws {
    let capture = CaptureStub()
    let screen = ScreenComposerCoordinator(captureService: capture)
    screen.draft = "existing question"
    _ = await screen.capture()
    let id = try XCTUnwrap(screen.attachment?.id)
    screen.draft = "/screen my unsent question"
    capture.image = nil
    let automatic = await screen.capture(submittedCommand: true)
    XCTAssertNil(automatic)
    XCTAssertEqual(screen.draft, "/screen my unsent question")
    XCTAssertEqual(screen.attachment?.id, id)
    XCTAssertFalse(screen.isCapturing)
  }

  func testCommandCapturesThenAutomaticallySubmitsOnlyWithQuestion() async {
    let screen = ScreenComposerCoordinator(captureService: CaptureStub())
    screen.draft = "/screen explain this code"
    let automatic = await screen.capture(submittedCommand: true)
    XCTAssertEqual(automatic, "explain this code")
    XCTAssertEqual(screen.draft, "explain this code")
    screen.draft = "/screen"
    let empty = await screen.capture(submittedCommand: true)
    XCTAssertNil(empty)
    XCTAssertEqual(screen.draft, "")
    XCTAssertNotNil(screen.attachment)
    screen.removeAttachment()
    XCTAssertNil(screen.attachment)
    XCTAssertFalse(screen.isEnabled)
  }

  func testCaptureDeletesTemporaryFileAndUsesUniquePNGPaths() async throws {
    var urls: [URL] = []
    var environment = ScreenCaptureService.Environment()
    environment.preflight = { true }
    environment.waitForPanel = {}
    environment.run = { url in
      urls.append(url)
      try Self.png().write(to: url)
    }
    let service = ScreenCaptureService(environment: environment)
    for _ in 0..<2 {
      let image = try await service.capture()
      XCTAssertNotNil(image)
    }
    XCTAssertNotEqual(urls[0], urls[1])
    XCTAssertTrue(urls.allSatisfy { $0.pathExtension == "png" && !FileManager.default.fileExists(atPath: $0.path) })
  }

  func testPermissionDeniedAndGrantedButRestartRequired() async {
    for granted in [false, true] {
      var environment = ScreenCaptureService.Environment()
      environment.preflight = { false }
      environment.requestAccess = { granted }
      environment.run = { _ in XCTFail("Capture must not launch without pixels available") }
      do {
        _ = try await ScreenCaptureService(environment: environment).capture()
        XCTFail("Expected permission failure")
      } catch {
        XCTAssertEqual(error as? ScreenCaptureError, granted ? .restartRequired : .permissionDenied)
      }
    }
  }

  func testNoFileMeansCancellationAndFailureDeletesFile() async throws {
    var environment = ScreenCaptureService.Environment()
    environment.preflight = { true }
    environment.waitForPanel = {}
    environment.run = { _ in }
    let cancelled = try await ScreenCaptureService(environment: environment).capture()
    XCTAssertNil(cancelled)
    var path: URL?
    environment.run = { url in path = url; try Data("broken".utf8).write(to: url) }
    do {
      _ = try await ScreenCaptureService(environment: environment).capture()
      XCTFail("Invalid image must fail")
    } catch {
      XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(path).path))
    }
  }

  func testPanelRemainsHiddenDuringCaptureAndRestoresItsFrame() throws {
    let view = NSTextField(string: "draft")
    let panel = SpotlightPanelController(glassAppearance: GlassAppearanceSettings(), contentView: view)
    panel.show()
    let window = try XCTUnwrap(view.window)
    let frame = window.frame
    defer { panel.hide() }
    NotificationCenter.default.post(name: .screenCaptureBegan, object: nil)
    XCTAssertFalse(panel.isVisible)
    XCTAssertTrue(window.isVisible, "Keep the compositor surface alive while the transparent panel is hidden")
    XCTAssertEqual(window.alphaValue, 0)
    XCTAssertTrue(window.ignoresMouseEvents)
    panel.toggle()
    XCTAssertFalse(panel.isVisible)
    NotificationCenter.default.post(name: .screenCaptureEnded, object: nil)
    XCTAssertTrue(panel.isVisible)
    XCTAssertEqual(window.alphaValue, 1)
    XCTAssertFalse(window.ignoresMouseEvents)
    XCTAssertEqual(window.frame, frame)
    XCTAssertEqual(view.stringValue, "draft")
  }

  static func png() throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }
}

@MainActor
private final class CaptureNotificationProbe: NSObject {
  var beginCount = 0
  var endCount = 0
  @objc func began() { beginCount += 1 }
  @objc func ended() { endCount += 1 }
}

@MainActor
private struct PermissionFailingCapture: ScreenCapturing {
  func prepareForCapture() throws { throw ScreenCaptureError.permissionDenied }
  func capture() async throws -> NSImage? {
    XCTFail("Capture must not start after permission preparation fails")
    return nil
  }
}

@MainActor
private final class CaptureStub: ScreenCapturing {
  var image: NSImage? = NSImage(size: NSSize(width: 20, height: 10), flipped: false) { rect in
    NSColor.white.setFill(); rect.fill(); return true
  }
  func capture() async throws -> NSImage? { image }
}
