import Foundation

/// The same catalog drives execution, syntax coloring, and completion.
enum SlashCommand: String, CaseIterable, Identifiable {
  case search, screen, snapshot, think

  var id: String { rawValue }
  var token: String { "/" + rawValue }
  var symbol: String {
    switch self {
    case .search: "globe"
    case .screen: "display.2"
    case .snapshot: "viewfinder"
    case .think: "brain"
    }
  }
  var description: String {
    switch self {
    case .search: "Search the web for this answer"
    case .screen: "Capture all displays"
    case .snapshot: "Select a screen region to capture"
    case .think: "Think more deeply for this answer"
    }
  }

  struct Token: Equatable {
    let command: SlashCommand
    let range: NSRange
  }
  struct Completion: Equatable {
    let range: NSRange
    let commands: [SlashCommand]
  }

  // Quoted examples and code are literal. Requiring whitespace before a slash
  // avoids interpreting URLs, paths, and escaped commands as tool requests.
  private static let candidates = try! NSRegularExpression(
    pattern: #"`[^`]*(?:`|$)|"[^"\n]*(?:"|$)|(?<!\S)(/[A-Za-z]*)(?=$|\s|[.,!?;:])"#)

  private static func ranges(in text: String) -> [NSRange] {
    candidates.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
      .map { $0.range(at: 1) }.filter { $0.location != NSNotFound }
  }

  static func tokens(in text: String) -> [Token] {
    let source = text as NSString
    return ranges(in: text).compactMap { range in
      guard let command = SlashCommand(rawValue: String(source.substring(with: range).dropFirst()).lowercased()) else { return nil }
      return Token(command: command, range: range)
    }
  }

  static func removing(_ commands: Set<SlashCommand>, from text: String) -> String {
    let result = NSMutableString(string: text)
    for token in tokens(in: text).reversed() where commands.contains(token.command) {
      result.deleteCharacters(in: token.range)
    }
    return (result as String).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func completion(in text: String, selection: NSRange) -> Completion? {
    guard selection.length == 0, selection.location != NSNotFound else { return nil }
    let source = text as NSString
    guard let range = ranges(in: text).first(where: {
      selection.location > $0.location && selection.location <= NSMaxRange($0)
    }) else { return nil }
    let prefix = source.substring(with: NSRange(location: range.location + 1,
      length: selection.location - range.location - 1)).lowercased()
    let matches = allCases.filter { $0.rawValue.hasPrefix(prefix) }
    guard !matches.isEmpty else { return nil }
    return Completion(range: range, commands: matches)
  }
}
