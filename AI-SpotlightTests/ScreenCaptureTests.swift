import AppKit
import XCTest
@testable import Enigma

@MainActor
final class ScreenCaptureTests: XCTestCase {
  func testSnapshotAndThinkingCommandsComposeAnywhere() {
    let commands = ComposerCommands("/think /snapshot /search explain /screen literally")
    XCTAssertTrue(commands.screen)
    XCTAssertTrue(commands.snapshot)
    XCTAssertTrue(commands.think)
    XCTAssertTrue(commands.search)
    XCTAssertEqual(commands.prompt, "explain  literally")
    XCTAssertEqual(commands.captureDraft, "/snapshot /think explain  literally")
    XCTAssertFalse(ComposerCommands("/snapshotting hi").screen)
    XCTAssertFalse(ComposerCommands("/thinker hi").think)
    XCTAssertTrue(ComposerCommands("explain /think").think)
  }

  func testDesktopAndSnapshotUseDifferentCapturePathsAndRetakeMatches() async throws {
    let capture = CaptureModeProbe()
    let coordinator = ScreenComposerCoordinator(captureService: capture)
    coordinator.draft = "/screen /think explain"
    let prompt = await coordinator.capture(submittedCommand: true)
    XCTAssertEqual(prompt, "/think explain")
    XCTAssertEqual(capture.desktopCount, 1)
    _ = await coordinator.capture()
    XCTAssertEqual(capture.desktopCount, 2)
    coordinator.draft = "/snapshot explain"
    _ = await coordinator.capture(submittedCommand: true)
    XCTAssertEqual(capture.regionCount, 1)
    _ = await coordinator.capture()
    XCTAssertEqual(capture.regionCount, 2)
  }

  func testDesktopCaptureWaitsForPanelAndPreflightsPermission() async throws {
    var environment = ScreenCaptureService.Environment()
    var waited = false
    environment.preflight = { true }
    environment.waitForPanel = { waited = true }
    environment.desktop = { XCTAssertTrue(waited); return NSImage(size: NSSize(width: 20, height: 20)) }
    environment.run = { _ in XCTFail("Desktop must not select a region") }
    let image = try await ScreenCaptureService(environment: environment).captureDesktop()
    XCTAssertNotNil(image)
  }

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

@MainActor
private final class CaptureModeProbe: ScreenCapturing {
  var desktopCount = 0
  var regionCount = 0
  func capture() async throws -> NSImage? { regionCount += 1; return image() }
  func captureDesktop() async throws -> NSImage? { desktopCount += 1; return image() }
  private func image() -> NSImage {
    let image = NSImage(size: NSSize(width: 20, height: 20))
    image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 20, height: 20).fill(); image.unlockFocus()
    return image
  }
}

@MainActor
final class SlashCommandTests: XCTestCase {
  func testCommandsAtEveryPositionAndCase() {
    for command in SlashCommand.allCases {
      for draft in [command.token + " hello", "hello " + command.token + " world", "hello " + command.token.uppercased()] {
        XCTAssertEqual(SlashCommand.tokens(in: draft).map(\.command), [command])
        XCTAssertFalse(ComposerCommands(draft).prompt.lowercased().contains(command.token))
      }
      XCTAssertNotNil(NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil))
    }
    XCTAssertTrue(ThinkCommand.message("solve this /think").extendedThinking == true)
    XCTAssertEqual(ThinkCommand.message("solve this /think").content, "solve this")
    XCTAssertTrue(ComposerCommands("hello /snapshot, please /search!").snapshot)
  }

  func testLiteralsAndUnknownCommandsRemainUntouched() {
    for text in ["https://example.com/search", "/tmp/screen", "`/think`", "\"/screen /search\"", "\\/think", "/thinker", "/unknown", "hello/think"] {
      XCTAssertTrue(SlashCommand.tokens(in: text).isEmpty, text)
      XCTAssertEqual(ComposerCommands(text).prompt, text)
    }
  }

  func testCompletionUsesCaretAndReplacesWholeToken() throws {
    let text = "🙂 explain /sn here"
    let range = (text as NSString).range(of: "/sn")
    let completion = try XCTUnwrap(SlashCommand.completion(in: text,
      selection: NSRange(location: NSMaxRange(range), length: 0)))
    XCTAssertEqual(completion.range, range)
    XCTAssertEqual(completion.commands, [.snapshot])
    XCTAssertEqual(SlashCommand.completion(in: "/S", selection: NSRange(location: 2, length: 0))?.commands,
                   [.search, .screen, .snapshot])
    XCTAssertEqual(SlashCommand.completion(in: "/", selection: NSRange(location: 1, length: 0))?.commands, SlashCommand.allCases)
    XCTAssertNil(SlashCommand.completion(in: "/unknown", selection: NSRange(location: 8, length: 0)))
    XCTAssertNil(SlashCommand.completion(in: text, selection: NSRange(location: range.location, length: 2)))
    XCTAssertNil(SlashCommand.completion(in: "`/sn`", selection: NSRange(location: 4, length: 0)))
    XCTAssertEqual(SlashCommand.completion(in: "/snapshot", selection: NSRange(location: 3, length: 0))?.range,
                   NSRange(location: 0, length: 9))
  }

  func testKeyboardCompletionDismissalAndNewlines() throws {
    let editor = SlashCommandTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
    let model = CommandCompletionModel()
    model.editor = editor
    editor.completion = model
    editor.string = "/s"
    editor.setSelectedRange(NSRange(location: 2, length: 0))
    model.refresh()
    var submissions = 0
    editor.submit = { submissions += 1 }
    func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) throws {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
        characters: code == 36 ? "\r" : "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
      editor.keyDown(with: event)
    }
    try key(125)
    XCTAssertEqual(model.selected, 1)
    try key(48)
    XCTAssertEqual(editor.string, "/screen ")
    XCTAssertEqual(submissions, 0)
    try key(36, .shift)
    XCTAssertEqual(editor.string, "/screen \n")
    XCTAssertEqual(submissions, 0)
    try key(36)
    XCTAssertEqual(submissions, 1)
    editor.string = "/th"
    editor.setSelectedRange(NSRange(location: 3, length: 0))
    model.refresh()
    try key(53)
    XCTAssertTrue(model.commands.isEmpty)
    XCTAssertEqual(editor.string, "/th")
  }

  func testCaptureCommandAtEndAndCancellationPreservesExactDraft() async {
    let capture = CaptureStub()
    let coordinator = ScreenComposerCoordinator(captureService: capture)
    coordinator.draft = "explain this /snapshot"
    let prompt = await coordinator.capture(submittedCommand: true)
    XCTAssertEqual(prompt, "explain this")
    coordinator.draft = "keep /snapshot this /think"
    capture.image = nil
    _ = await coordinator.capture(submittedCommand: true)
    XCTAssertEqual(coordinator.draft, "keep /snapshot this /think")
  }

  func testHighlightingAndCompletionPreserveDraftSelectionAndUndo() throws {
    let editor = SlashCommandTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
    let model = CommandCompletionModel()
    model.editor = editor
    editor.completion = model
    editor.allowsUndo = true
    let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = editor
    editor.string = "🙂 /think explain /sn please"
    let range = (editor.string as NSString).range(of: "/sn")
    editor.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
    let selection = editor.selectedRange()
    editor.highlightCommands()
    XCTAssertEqual(editor.selectedRange(), selection)
    let think = (editor.string as NSString).range(of: "/think")
    XCTAssertEqual(editor.textStorage?.attribute(.foregroundColor, at: think.location, effectiveRange: nil) as? NSColor, .systemBlue)
    XCTAssertEqual(editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .labelColor)
    model.refresh()
    model.accept(.snapshot)
    XCTAssertEqual(editor.string, "🙂 /think explain /snapshot please")
    XCTAssertTrue(model.commands.isEmpty)
    editor.undoManager?.undo()
    XCTAssertEqual(editor.string, "🙂 /think explain /sn please")
  }
}
