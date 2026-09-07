import AppKit
import Combine

@MainActor
final class ScreenComposerCoordinator: ObservableObject {
  @Published var draft = ""
  @Published var isEnabled = false
  @Published var isPresented = false
  @Published private(set) var attachment: ScreenAttachment?
  @Published private(set) var isCapturing = false
  @Published private(set) var isReading = false
  var isBusy: Bool { isCapturing || isReading }
  @Published var error: String?
  private let captureService: any ScreenCapturing
  private let ocrService: any ScreenOCRReading
  private var revision = UUID()
  private var lastCaptureWasDesktop = false

  init(captureService: any ScreenCapturing = ScreenCaptureService(), ocrService: any ScreenOCRReading = ScreenOCRService()) {
    self.captureService = captureService
    self.ocrService = ocrService
  }

  /// Returns an automatic submission only for a successful leading /screen with a question.
  func capture(submittedCommand: Bool = false) async -> String? {
    guard !isBusy else { return nil }
    let originalDraft = draft
    let commands = ComposerCommands(draft)
    let desktop = submittedCommand ? !commands.snapshot : lastCaptureWasDesktop
    let remainder = submittedCommand && commands.screen ? commands.submissionPrompt : nil
    let operation = UUID()
    revision = operation
    isCapturing = true
    error = nil
    defer { isCapturing = false; isReading = false }
    do {
      guard let image = try await captureRegion(desktop: desktop) else { return nil }
      try Task.checkCancellation()
      guard revision == operation else { return nil }
      attachment = try ScreenAttachment(image: image, source: desktop ? .fullDesktop : .screenRegion)
      lastCaptureWasDesktop = desktop
      isPresented = true
      isEnabled = true
      isCapturing = false
      isReading = true
      attachment?.status = .reading
      if let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        let result: ScreenOCRResult
        do { result = try await ocrService.recognize(pixels) }
        catch is CancellationError { return nil }
        catch { result = .empty } // An OCR failure can still be handled by vision.
        guard revision == operation else { return nil }
        attachment?.ocrText = result.text
        attachment?.ocrConfidence = result.confidence
        attachment?.status = result.isUsable ? .localOCR : .vision
      }
      guard draft == originalDraft else { return nil }
      if let remainder { draft = remainder }
      return remainder.flatMap { ThinkCommand.message($0).content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    } catch is CancellationError {
      return nil
    } catch {
      self.error = error.localizedDescription
      return nil
    }
  }

  private func captureRegion(desktop: Bool) async throws -> NSImage? {
    // Permission UI belongs in front of the visible panel. Hide only once the
    // process is authorized and interactive region selection is about to start.
    try captureService.prepareForCapture()
    NotificationCenter.default.post(name: .screenCaptureBegan, object: nil)
    defer { NotificationCenter.default.post(name: .screenCaptureEnded, object: nil) }
    return try await desktop ? captureService.captureDesktop() : captureService.capture()
  }

  func updateDecision(_ decision: ScreenRoutingPolicy.Decision) {
    attachment?.routingDecision = decision
    if case .text = decision { attachment?.status = .localOCR }
    if case .vision = decision { attachment?.status = .vision }
  }

  func removeAttachment() {
    revision = UUID()
    attachment = nil
    isEnabled = false
    error = nil
  }

  func clearDraft() {
    removeAttachment()
    draft = ""
    isPresented = false
  }
}

extension Notification.Name {
  static let screenCaptureBegan = Notification.Name("aiSpotlight.screenCaptureBegan")
  static let screenCaptureEnded = Notification.Name("aiSpotlight.screenCaptureEnded")
}
