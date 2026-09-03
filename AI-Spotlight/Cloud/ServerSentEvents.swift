import Foundation

struct ServerSentEvent: Equatable, Sendable {
  let event: String?
  let data: String
}

struct ServerSentEventParser: Sendable {
  private var buffer = Data()
  private var eventName: String?
  private var dataLines: [String] = []

  mutating func append(_ chunk: Data) -> [ServerSentEvent] {
    buffer.append(chunk)
    var events: [ServerSentEvent] = []
    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
      var line = Data(buffer[..<newlineIndex])
      buffer.removeSubrange(...newlineIndex)
      if line.last == 0x0D { line.removeLast() }
      parseLine(String(decoding: line, as: UTF8.self), into: &events)
    }
    return events
  }

  mutating func finish() -> [ServerSentEvent] {
    var events: [ServerSentEvent] = []
    if !buffer.isEmpty {
      var line = buffer
      buffer.removeAll()
      if line.last == 0x0D { line.removeLast() }
      parseLine(String(decoding: line, as: UTF8.self), into: &events)
    }
    dispatch(into: &events)
    return events
  }

  private mutating func parseLine(_ line: String, into events: inout [ServerSentEvent]) {
    guard !line.isEmpty else {
      dispatch(into: &events)
      return
    }
    guard !line.hasPrefix(":") else { return }

    let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let field = String(parts[0])
    var value = parts.count == 2 ? String(parts[1]) : ""
    if value.hasPrefix(" ") { value.removeFirst() }
    switch field {
    case "event":
      eventName = value
    case "data":
      dataLines.append(value)
    default:
      break
    }
  }

  private mutating func dispatch(into events: inout [ServerSentEvent]) {
    guard eventName != nil || !dataLines.isEmpty else { return }
    events.append(ServerSentEvent(event: eventName, data: dataLines.joined(separator: "\n")))
    eventName = nil
    dataLines.removeAll(keepingCapacity: true)
  }
}
