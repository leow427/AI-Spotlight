import CoreGraphics
import Foundation
import Vision

struct ScreenOCRLine: Sendable, Equatable {
  let text: String
  let confidence: Float
  /// Vision coordinates: origin at the bottom left, normalized to the image.
  let bounds: CGRect
}

struct ScreenOCRResult: Sendable, Equatable {
  let text: String
  let confidence: Float
  static let empty = ScreenOCRResult(text: "", confidence: 0)
  var nonWhitespaceCharacterCount: Int { text.filter { !$0.isWhitespace }.count }
  var isUsable: Bool { nonWhitespaceCharacterCount >= 40 && confidence.isFinite && confidence >= 0.55 }

  static func assemble(_ observations: [ScreenOCRLine]) -> ScreenOCRResult {
    let lines = observations.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .sorted { $0.bounds.midY > $1.bounds.midY }
    guard !lines.isEmpty else { return .empty }
    // Group against a fixed row anchor; a pairwise tolerance comparator is not transitive.
    var rows: [[ScreenOCRLine]] = []
    for line in lines {
      if let anchor = rows.last?.first,
         abs(anchor.bounds.midY - line.bounds.midY) <= min(anchor.bounds.height, line.bounds.height) * 0.5 {
        rows[rows.count - 1].append(line)
      } else { rows.append([line]) }
    }
    let ordered = rows.flatMap { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
    let average = ordered.reduce(Float(0)) {
      $0 + ($1.confidence.isFinite ? min(1, max(0, $1.confidence)) : 0)
    } / Float(ordered.count)
    return ScreenOCRResult(text: ordered.map(\.text).joined(separator: "\n"), confidence: average)
  }
}

protocol ScreenOCRReading: Sendable {
  func recognize(_ image: CGImage) async throws -> ScreenOCRResult
}

struct ScreenOCRService: ScreenOCRReading {
  func recognize(_ image: CGImage) async throws -> ScreenOCRResult {
    let worker = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = false
      request.automaticallyDetectsLanguage = true
      let handler = VNImageRequestHandler(cgImage: image, options: [:])
      try handler.perform([request])
      try Task.checkCancellation()
      return ScreenOCRResult.assemble((request.results ?? []).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        return ScreenOCRLine(text: candidate.string, confidence: candidate.confidence, bounds: observation.boundingBox)
      })
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: { worker.cancel() }
  }
}
