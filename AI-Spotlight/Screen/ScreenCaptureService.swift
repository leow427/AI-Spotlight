import AppKit
import CoreGraphics

protocol ScreenCapturing: Sendable {
  @MainActor func prepareForCapture() throws
  @MainActor func capture() async throws -> NSImage?
  @MainActor func captureDesktop() async throws -> NSImage?
}

extension ScreenCapturing {
  @MainActor func prepareForCapture() throws {}
  @MainActor func captureDesktop() async throws -> NSImage? { try await capture() }
}

enum ScreenCaptureError: LocalizedError, Equatable {
  case permissionDenied, restartRequired, invalidImage, alreadyCapturing
  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      "macOS is not granting Screen Recording to this copy of AI Spotlight. If PrimaryAgent is already enabled in System Settings, remove that stale entry, add the currently running app, then quit and reopen AI Spotlight. Your draft has been kept."
    case .restartRequired:
      "Screen Recording permission was granted. Quit and reopen AI Spotlight to make screenshot pixels available, then try again. Your draft has been kept."
    case .invalidImage: "The screenshot could not be read. Please retake it."
    case .alreadyCapturing: "Finish the current screen selection first."
    }
  }
}

@MainActor
final class ScreenCaptureService: ScreenCapturing {
  struct Environment {
    var preflight: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var requestAccess: () -> Bool = { CGRequestScreenCaptureAccess() }
    var waitForPanel: () async throws -> Void = { try await Task.sleep(for: .milliseconds(200)) }
    var run: (URL) async throws -> Void = ScreenCaptureService.runSelection
    var desktop: () async throws -> NSImage? = ScreenCaptureService.runDesktop
    var temporaryDirectory = FileManager.default.temporaryDirectory
  }
  private let environment: Environment
  private var isCapturing = false
  private var hasPreparedCapture = false

  init(environment: Environment = Environment()) { self.environment = environment }

  func prepareForCapture() throws {
    guard !isCapturing else { throw ScreenCaptureError.alreadyCapturing }
    try ensurePermission()
    hasPreparedCapture = true
  }

  func capture() async throws -> NSImage? { try await capture(fullDesktop: false) }

  func captureDesktop() async throws -> NSImage? { try await capture(fullDesktop: true) }

  private func capture(fullDesktop: Bool) async throws -> NSImage? {
    guard !isCapturing else { throw ScreenCaptureError.alreadyCapturing }
    let wasPrepared = hasPreparedCapture
    hasPreparedCapture = false
    isCapturing = true
    defer { isCapturing = false }
    if !wasPrepared { try ensurePermission() }
    try await environment.waitForPanel()
    try Task.checkCancellation()
    if fullDesktop { return try await environment.desktop() }
    let url = environment.temporaryDirectory.appendingPathComponent("ai-spotlight-screen-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    try await environment.run(url)
    try Task.checkCancellation()
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    // Force decoding before unlinking, rather than keeping a lazy file-backed image.
    let data = try Data(contentsOf: url)
    guard let bitmap = NSBitmapImageRep(data: data), let pixels = bitmap.cgImage else {
      throw ScreenCaptureError.invalidImage
    }
    return NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
  }

  private func ensurePermission() throws {
    guard !environment.preflight() else { return }
    guard environment.requestAccess() else { throw ScreenCaptureError.permissionDenied }
    guard environment.preflight() else { throw ScreenCaptureError.restartRequired }
  }

  /// Capture every attached display and preserve their desktop arrangement.
  private static func runDesktop() async throws -> NSImage? {
    let screens = NSScreen.screens
    guard !screens.isEmpty else { throw ScreenCaptureError.invalidImage }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ai-spotlight-desktop-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let urls = screens.indices.map { directory.appendingPathComponent("display-\($0).png") }
    try await runCapture(["-x"] + urls.map(\.path))
    try Task.checkCancellation()
    let bounds = screens.reduce(NSRect.null) { $0.union($1.frame) }
    let result = NSImage(size: bounds.size)
    result.lockFocus()
    defer { result.unlockFocus() }
    for (screen, url) in zip(screens, urls) {
      guard let image = NSImage(data: try Data(contentsOf: url)) else { throw ScreenCaptureError.invalidImage }
      image.draw(in: screen.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY),
                 from: .zero, operation: .copy, fraction: 1)
    }
    return result
  }

  private static func runSelection(_ url: URL) async throws {
    try await runCapture(["-i", "-x", url.path])
  }

  private static func runCapture(_ arguments: [String]) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { _ in continuation.resume() }
        do {
          try process.run()
          if Task.isCancelled && process.isRunning { process.terminate() }
        }
        catch { continuation.resume(throwing: error) }
      }
    } onCancel: {
      // Process is thread-safe. Termination causes the continuation above to resume.
      if process.isRunning { process.terminate() }
    }
  }
}
