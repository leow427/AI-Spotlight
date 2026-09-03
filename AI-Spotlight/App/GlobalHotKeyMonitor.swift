@preconcurrency import Carbon
import Foundation

enum GlobalHotKeyError: LocalizedError {
  case eventHandlerInstallationFailed(OSStatus)
  case registrationFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .eventHandlerInstallationFailed(let status):
      "The keyboard event handler could not be installed (status \(status))."
    case .registrationFailed(let status):
      "Option-Space could not be registered (status \(status))."
    }
  }
}

// Carbon invokes handlers installed on the application event target on the main event loop.
// The unchecked conformance documents that the mutable registration references stay there.
final class GlobalHotKeyMonitor: @unchecked Sendable {
  private static let signature: OSType = 0x4149_5350 // AISP
  private static let identifier: UInt32 = 1

  private let handler: @MainActor () -> Void
  private var eventHandler: EventHandlerRef?
  private var hotKey: EventHotKeyRef?

  init(handler: @escaping @MainActor () -> Void) {
    self.handler = handler
  }

  func start() throws {
    guard hotKey == nil else { return }

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let handlerStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      globalHotKeyEventHandler,
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler
    )
    guard handlerStatus == noErr else {
      throw GlobalHotKeyError.eventHandlerInstallationFailed(handlerStatus)
    }

    let hotKeyID = EventHotKeyID(
      signature: Self.signature,
      id: Self.identifier
    )
    let registrationStatus = RegisterEventHotKey(
      UInt32(kVK_Space),
      UInt32(optionKey),
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
    guard registrationStatus == noErr else {
      stop()
      throw GlobalHotKeyError.registrationFailed(registrationStatus)
    }
  }

  func stop() {
    if let hotKey {
      UnregisterEventHotKey(hotKey)
      self.hotKey = nil
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }

  fileprivate func receive(_ event: EventRef) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
      event,
      EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == Self.signature,
          hotKeyID.id == Self.identifier else {
      return OSStatus(eventNotHandledErr)
    }

    MainActor.assumeIsolated {
      handler()
    }
    return noErr
  }
}

private func globalHotKeyEventHandler(
  _ nextHandler: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event, let userData else { return OSStatus(eventNotHandledErr) }
  let monitor = Unmanaged<GlobalHotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
  return monitor.receive(event)
}
