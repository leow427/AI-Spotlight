@preconcurrency import Carbon
import Foundation

enum GlobalHotKey: CaseIterable {
  case togglePanel
  case openSettings
  case selectionContext

  var keyCode: UInt32 {
    switch self {
    case .togglePanel: UInt32(kVK_Space)
    case .openSettings: UInt32(kVK_ANSI_S)
    case .selectionContext: UInt32(kVK_Space)
    }
  }

  var modifiers: UInt32 { self == .selectionContext ? UInt32(optionKey | shiftKey) : UInt32(optionKey) }

  fileprivate var identifier: UInt32 {
    switch self {
    case .togglePanel: 1
    case .openSettings: 2
    case .selectionContext: 3
    }
  }

  fileprivate var displayName: String {
    switch self {
    case .togglePanel: "Option-Space"
    case .openSettings: "Option-S"
    case .selectionContext: "Shift-Option-Space"
    }
  }
}

enum GlobalHotKeyError: LocalizedError {
  case eventHandlerInstallationFailed(OSStatus)
  case registrationFailed(GlobalHotKey, OSStatus)

  var errorDescription: String? {
    switch self {
    case .eventHandlerInstallationFailed(let status):
      "The keyboard event handler could not be installed (status \(status))."
    case .registrationFailed(let hotKey, let status):
      "\(hotKey.displayName) could not be registered (status \(status))."
    }
  }
}

// Carbon invokes handlers installed on the application event target on the main event loop.
// The unchecked conformance documents that the mutable registration references stay there.
final class GlobalHotKeyMonitor: @unchecked Sendable {
  private static let signature: OSType = 0x4149_5350 // AISP

  private let hotKeyDefinition: GlobalHotKey
  private let handler: @MainActor () -> Void
  private var eventHandler: EventHandlerRef?
  private var hotKey: EventHotKeyRef?

  init(
    hotKey: GlobalHotKey,
    handler: @escaping @MainActor () -> Void
  ) {
    self.hotKeyDefinition = hotKey
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
      id: hotKeyDefinition.identifier
    )
    let registrationStatus = RegisterEventHotKey(
      hotKeyDefinition.keyCode,
      hotKeyDefinition.modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
    guard registrationStatus == noErr else {
      stop()
      throw GlobalHotKeyError.registrationFailed(hotKeyDefinition, registrationStatus)
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
          hotKeyID.id == hotKeyDefinition.identifier else {
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
