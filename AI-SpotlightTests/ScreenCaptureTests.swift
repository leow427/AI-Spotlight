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

  func testPanelIsRemovedDuringCaptureAndRestoresItsContentAndFrame() throws {
    let view = NSTextField(string: "draft")
    let panel = SpotlightPanelController(glassAppearance: GlassAppearanceSettings(), contentView: view)
    panel.show()
    let window = try XCTUnwrap(view.window)
    let frame = window.frame
    defer { panel.hide() }
    for _ in 0..<3 {
      NotificationCenter.default.post(name: .screenCaptureBegan, object: nil)
      XCTAssertFalse(panel.isVisible)
      XCTAssertFalse(window.isVisible, "The panel must leave the window server while the user selects a region")
      XCTAssertEqual(window.alphaValue, 1)
      XCTAssertFalse(window.ignoresMouseEvents)
      panel.toggle()
      XCTAssertFalse(panel.isVisible)
      NotificationCenter.default.post(name: .screenCaptureEnded, object: nil)
      XCTAssertTrue(panel.isVisible)
      XCTAssertEqual(window.alphaValue, 1)
      XCTAssertFalse(window.ignoresMouseEvents)
      XCTAssertEqual(window.frame, frame)
      XCTAssertEqual(view.stringValue, "draft")
    }
  }

  func testOverlappingCaptureIsRejectedAndCancellationBalancesPanelNotifications() async throws {
    let capture = SuspendedPanelCapture()
    let screen = ScreenComposerCoordinator(captureService: capture)
    let probe = CaptureNotificationProbe()
    NotificationCenter.default.addObserver(probe, selector: #selector(CaptureNotificationProbe.began), name: .screenCaptureBegan, object: nil)
    NotificationCenter.default.addObserver(probe, selector: #selector(CaptureNotificationProbe.ended), name: .screenCaptureEnded, object: nil)
    defer { NotificationCenter.default.removeObserver(probe) }
    let view = NSTextField(string: "draft")
    let controller = SpotlightPanelController(glassAppearance: GlassAppearanceSettings(), contentView: view)
    controller.show()
    defer { controller.hide() }
    let window = try XCTUnwrap(view.window)
    screen.draft = "/screen keep this question"
    let task = Task { await screen.capture(submittedCommand: true) }
    await fulfillment(of: [capture.started], timeout: 3)
    XCTAssertTrue(controller.isCapturingScreen)
    XCTAssertFalse(window.isVisible)
    let overlapping = await screen.capture(submittedCommand: true)
    XCTAssertNil(overlapping)
    XCTAssertEqual(probe.beginCount, 1)
    XCTAssertEqual(probe.endCount, 0)
    XCTAssertEqual(capture.calls, 1)
    task.cancel()
    capture.complete()
    let cancelled = await task.value
    XCTAssertNil(cancelled)
    XCTAssertEqual(probe.endCount, 1)
    XCTAssertEqual(screen.draft, "/screen keep this question")
    XCTAssertNil(screen.attachment)
    XCTAssertFalse(screen.isBusy)
    XCTAssertFalse(controller.isCapturingScreen)
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(window.isKeyWindow)
    NotificationCenter.default.post(name: .screenCaptureEnded, object: nil)
    XCTAssertTrue(controller.isVisible, "A duplicate end must not hide the restored panel")
  }

  func testRemovingAttachmentDuringOCRDiscardsLateResultAndAutomaticSubmission() async throws {
    let ocr = SuspendedPanelOCR()
    let screen = ScreenComposerCoordinator(captureService: CaptureStub(), ocrService: ocr)
    screen.draft = "/screen original question"
    let task = Task { await screen.capture(submittedCommand: true) }
    await fulfillment(of: [ocr.started], timeout: 3)
    XCTAssertNotNil(screen.attachment)
    XCTAssertTrue(screen.isReading)
    screen.removeAttachment()
    screen.draft = "replacement draft"
    await ocr.complete()
    let automatic = await task.value
    XCTAssertNil(automatic)
    XCTAssertNil(screen.attachment)
    XCTAssertEqual(screen.draft, "replacement draft")
    XCTAssertFalse(screen.isBusy)
    XCTAssertFalse(screen.isEnabled)
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

@MainActor
private final class SuspendedPanelCapture: ScreenCapturing {
  let started = XCTestExpectation(description: "Capture is selecting")
  private var continuation: CheckedContinuation<NSImage?, Never>?
  private(set) var calls = 0
  func capture() async throws -> NSImage? {
    calls += 1
    return await withCheckedContinuation {
      continuation = $0
      started.fulfill()
    }
  }
  func complete() {
    continuation?.resume(returning: CaptureStub().image)
    continuation = nil
  }
}

private actor SuspendedPanelOCR: ScreenOCRReading {
  nonisolated let started = XCTestExpectation(description: "OCR is reading")
  private var continuation: CheckedContinuation<ScreenOCRResult, Never>?
  func recognize(_ image: CGImage) async throws -> ScreenOCRResult {
    await withCheckedContinuation {
      continuation = $0
      started.fulfill()
    }
  }
  func complete() {
    continuation?.resume(returning: ScreenOCRResult(text: "late extracted text", confidence: 0.99))
    continuation = nil
  }
}
