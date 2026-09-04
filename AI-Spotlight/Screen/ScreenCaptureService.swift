import AppKit
import CoreGraphics

protocol ScreenCapturing: Sendable {
  @MainActor func capture() async throws -> NSImage?
}

enum ScreenCaptureError: LocalizedError, Equatable {
  case permissionDenied, restartRequired, invalidImage, alreadyCapturing
  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      "Allow AI Spotlight in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
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
    var temporaryDirectory = FileManager.default.temporaryDirectory
  }
  private let environment: Environment
  private var isCapturing = false

  init(environment: Environment = Environment()) { self.environment = environment }

  func capture() async throws -> NSImage? {
    guard !isCapturing else { throw ScreenCaptureError.alreadyCapturing }
    isCapturing = true
    defer { isCapturing = false }
    if !environment.preflight() {
      guard environment.requestAccess() else { throw ScreenCaptureError.permissionDenied }
      guard environment.preflight() else { throw ScreenCaptureError.restartRequired }
    }
    try await environment.waitForPanel()
    try Task.checkCancellation()
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

  private static func runSelection(_ url: URL) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-i", "-x", url.path]
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
