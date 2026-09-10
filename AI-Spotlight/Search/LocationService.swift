import Combine
@preconcurrency import CoreLocation
import Foundation
import MapKit

/// Only the current question can request location, never quoted or attached content.
enum LocationIntent {
  static func needsLocation(_ prompt: String) -> Bool {
    let text = WebSearchPolicy.questionText(prompt)
    guard !WebSearchPolicy.isOfflineOrTransformation(text),
          !matches(#"\b(?:(?:do not|don't|dont|never) (?:use|access|share|detect) (?:my |the )?location|without (?:my )?location)\b"#, text) else { return false }
    if matches(#"\b(?:in|at|near)\s+(?!(?:me|my|this|the|here)\b)[a-z]"#, text) { return false }
    if matches(#"\b(?:near me|around me|nearby|my (?:current )?location|where am i|in my area|locally|local (?:weather|restaurants?|cafes?|events|places))\b"#, text) { return true }
    guard matches(#"\b(?:weather|forecast|temperature|rain|snow|umbrella)\b"#, text) else { return false }
    // Named destinations take precedence over the device's location.
    if matches(#"\b(?:in|at|for|near)\s+(?!(?:today|tonight|tomorrow|this|the next)\b)[a-z]"#, text) { return false }
    if matches(#"^(?:what is|what's|define|explain|how does) (?:the |a )?(?:weather|rain|snow|temperature)(?: work| mean)?[?.!]*$"#, text) { return false }
    return matches(#"\b(?:today|tonight|tomorrow|this week|forecast|will it|is it|what's|what is|what are|do i need)\b"#, text)
  }

  private static func matches(_ pattern: String, _ text: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
  }
}

struct ApproximateLocation: Equatable, Sendable {
  let area: String
  let coordinates: String
  var searchContext: String { "Approximate current location: \(area) (\(coordinates))" }

  init(latitude: Double, longitude: Double, area: String = "current area") {
    self.area = area
    coordinates = String(format: "%.2f, %.2f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
  }
}

enum LocationError: LocalizedError {
  case unavailable
  var errorDescription: String? {
    "Your location is unavailable. Include a city or area in your question, or enable location access in Settings."
  }
}

@MainActor
protocol LocationProviding: AnyObject {
  func currentLocation() async throws -> ApproximateLocation
}

/// A bounded, cancellable one-shot request. The service does not persist location.
@MainActor
final class LocationService: NSObject, ObservableObject, @MainActor CLLocationManagerDelegate, LocationProviding {
  static let shared = LocationService()
  @Published var isEnabled: Bool {
    didSet {
      defaults.set(isEnabled, forKey: "location.enabled")
      if !isEnabled { finish(.failure(LocationError.unavailable)) }
    }
  }
  @Published private(set) var status = "Location is requested only for nearby questions."
  private let defaults: UserDefaults
  private var manager: CLLocationManager?
  private var geocoder: MKReverseGeocodingRequest?
  private var continuation: CheckedContinuation<ApproximateLocation, Error>?
  private var requestID: UUID?
  private var timeout: Task<Void, Never>?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isEnabled = defaults.object(forKey: "location.enabled") as? Bool ?? true
    super.init()
  }

  func currentLocation() async throws -> ApproximateLocation {
    try Task.checkCancellation()
    guard isEnabled, continuation == nil else { throw LocationError.unavailable }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        requestID = id
        let manager = CLLocationManager()
        self.manager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        status = "Finding your approximate location…"
        timeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(20)) } catch { return }
          guard self?.requestID == id else { return }
          self?.finish(.failure(LocationError.unavailable))
        }
        switch manager.authorizationStatus {
        case .denied, .restricted: finish(.failure(LocationError.unavailable))
        default:
          // macOS presents its permission prompt when location is first requested.
          manager.requestLocation()
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard self?.requestID == id else { return }
        self?.finish(.failure(CancellationError()))
      }
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard self.manager === manager else { return }
    if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
      finish(.failure(LocationError.unavailable))
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard self.manager === manager, geocoder == nil,
          let location = locations.last(where: { $0.horizontalAccuracy >= 0 && abs($0.timestamp.timeIntervalSinceNow) < 300 }) else { return }
    manager.stopUpdatingLocation()
    // Round before reverse geocoding or sharing with search/model providers.
    let latitude = (location.coordinate.latitude * 100).rounded() / 100
    let longitude = (location.coordinate.longitude * 100).rounded() / 100
    let fallback = ApproximateLocation(latitude: latitude, longitude: longitude)
    guard let geocoder = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)) else {
      finish(.success(fallback))
      return
    }
    self.geocoder = geocoder
    geocoder.getMapItems { [weak self, weak manager] items, _ in
      guard let self, let manager, self.manager === manager else { return }
      let area = items?.first?.addressRepresentations?.cityWithContext ?? ""
      self.finish(.success(area.isEmpty ? fallback : ApproximateLocation(latitude: latitude, longitude: longitude, area: area)))
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard self.manager === manager else { return }
    finish(.failure(LocationError.unavailable))
  }

  private func finish(_ result: Result<ApproximateLocation, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    requestID = nil
    timeout?.cancel()
    timeout = nil
    manager?.stopUpdatingLocation()
    manager?.delegate = nil
    manager = nil
    geocoder?.cancel()
    geocoder = nil
    switch result {
    case .success: status = "Location was used for your last nearby question."
    case .failure(let error): status = error is CancellationError ? "Location request cancelled." : LocationError.unavailable.localizedDescription
    }
    continuation.resume(with: result)
  }
}
