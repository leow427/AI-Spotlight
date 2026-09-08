import SwiftUI

/// Display-only repair. Stored messages and provider streams remain verbatim.
enum ChatResponseNormalizer {
  static func normalize(_ source: String, escapingPathsForParser: Bool = false) -> String {
    var fence: (Character, Int)?
    var inlineFence: Int?
    return source.components(separatedBy: "\n").map { original in
      if let width = inlineFence {
        // Code spans can cross a soft line break; avoid repairing their contents.
        let pattern = "(?<!`)`{" + String(width) + "}(?!`)"
        if original.range(of: pattern, options: .regularExpression) != nil || original.isEmpty { inlineFence = nil }
        return original
      }
      let trimmed = original.drop(while: { $0 == " " || $0 == "\t" })
      if let active = fence {
        if trimmed.prefix(while: { $0 == active.0 }).count >= active.1,
           trimmed.drop(while: { $0 == active.0 }).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
        return original
      }
      if let first = trimmed.first, first == "`" || first == "~" {
        let count = trimmed.prefix(while: { $0 == first }).count
        if count >= 3 { fence = (first, count); return original }
      }
      if original.hasPrefix("    ") || original.hasPrefix("\t") { return original }
      // Keep code spans (including an unfinished streamed span), paths and URLs untouched.
      let protected = try! NSRegularExpression(pattern: #"(`+)[\s\S]*?\1|`+[^`]*$|(?:[A-Za-z]:\\|\\\\|\.{1,2}[/\\]|/)[^\s]+|\\\[[^\]\n]+\\?\]\\?\(https?://[^\s)]+\\?\)|https?://[^\s]+"#)
      let ns = original as NSString
      var result = ""
      var offset = 0
      for match in protected.matches(in: original, range: NSRange(location: 0, length: ns.length)) {
        result += repair(ns.substring(with: NSRange(location: offset, length: match.range.location - offset)), atLineStart: offset == 0)
        let literal = ns.substring(with: match.range)
        if literal.hasPrefix("`") {
          let width = literal.prefix(while: { $0 == "`" }).count
          if literal.count < width * 2 || !literal.hasSuffix(String(repeating: "`", count: width)) { inlineFence = width }
        }
        if literal.hasPrefix(#"\["#) {
          result += literal.replacingOccurrences(of: #"\\([\[\]()])"#, with: "$1", options: .regularExpression)
        } else if escapingPathsForParser, !literal.hasPrefix("`"), !literal.hasPrefix("http") {
          // Markdown consumes backslashes before punctuation even in a plain path.
          result += literal.replacingOccurrences(of: #"\"#, with: #"\\"#)
        } else { result += literal }
        offset = NSMaxRange(match.range)
      }
      result += repair(ns.substring(from: offset), atLineStart: offset == 0)
      return result
    }.joined(separator: "\n")
  }

  private static func repair(_ source: String, atLineStart: Bool) -> String {
    var text = source
    for scalar in ["\u{00a0}", "\u{2007}", "\u{202f}", "\u{2009}"] { text = text.replacingOccurrences(of: scalar, with: " ") }
    for scalar in ["\u{200b}", "\u{feff}"] { text = text.replacingOccurrences(of: scalar, with: "") }
    text = text.replacingOccurrences(of: "\r", with: "")
    func replace(_ pattern: String, _ template: String) {
      text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
    if atLineStart {
      if let range = text.range(of: ##"^ {0,3}(?:\\#){1,6}(?=\s+\S)"##, options: .regularExpression) {
        text.replaceSubrange(range, with: text[range].replacingOccurrences(of: #"\"#, with: ""))
      }
      replace(#"^( {0,3})\\(#{1,6})(?=\s+\S)"#, "$1$2")
      replace(#"^( {0,3})\\([-+*>])(?=\s+\S)"#, "$1$2")
      replace(#"^( {0,3}\d{1,9})\\([.)])(?=\s+\S)"#, "$1$2")
    }
    // Paired delimiters are evidence of formatting; unmatched escapes stay literal.
    replace(#"(?<![\\\w])\\\*\\\*(\S(?:.*?\S)?)\\\*\\\*(?!\w)"#, "**$1**")
    replace(#"(?<![\\\w])\\(\*\*|__)(\S(?:.*?\S)?)\\\1(?!\w)"#, "$1$2$1")
    replace(#"(?<![\\\w])\\([*_])(\S(?:.*?\S)?)\\\1(?!\w)"#, "$1$2$1")
    return text
  }
}

struct ChatMarkdownBlock: Identifiable {
  let id: Int
  var text: AttributedString
  let components: [PresentationIntent.IntentType]
}

enum ChatMarkdown {
  static func blocks(_ source: String) -> [ChatMarkdownBlock] {
    let normalized = ChatResponseNormalizer.normalize(source, escapingPathsForParser: true)
    guard let parsed = try? AttributedString(markdown: normalized, options: .init(interpretedSyntax: .full)) else {
      return [ChatMarkdownBlock(id: 0, text: AttributedString(normalized), components: [])]
    }
    var blocks: [ChatMarkdownBlock] = []
    for run in parsed.runs {
      let components = run.presentationIntent?.components ?? []
      let id = components.first?.identity ?? 0
      var text = AttributedString(parsed[run.range])
      if run.inlinePresentationIntent?.contains(.code) == true { text.font = .system(size: 13, design: .monospaced) }
      if blocks.last?.id == id { blocks[blocks.count - 1].text.append(text) }
      else { blocks.append(ChatMarkdownBlock(id: id, text: text, components: components)) }
    }
    return blocks
  }
}

struct ChatMarkdownView: View {
  let content: String

  var body: some View {
    let blocks = ChatMarkdown.blocks(content)
    VStack(alignment: .leading, spacing: 10) {
      ForEach(groups(blocks), id: \.first?.id) { group in
        if group.first?.components.contains(where: { if case .table = $0.kind { return true }; return false }) == true {
          ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
              ForEach(rows(group), id: \.first?.id) { row in
                GridRow {
                  ForEach(row) { cell in
                    Text(cell.text)
                      .fontWeight(cell.components.contains(where: { $0.kind == .tableHeaderRow }) ? .semibold : .regular)
                  }
                }
              }
            }.padding(12)
          }.background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        } else {
          ForEach(group) { block in blockView(block) }
        }
      }
    }.font(ChatTypography.body).lineSpacing(4).textSelection(.enabled)
  }

  private func groups(_ blocks: [ChatMarkdownBlock]) -> [[ChatMarkdownBlock]] {
    var groups: [[ChatMarkdownBlock]] = []
    for block in blocks {
      let table = block.components.first { if case .table = $0.kind { return true }; return false }
      if let table, groups.last?.last?.components.contains(table) == true { groups[groups.count - 1].append(block) }
      else { groups.append([block]) }
    }
    return groups
  }

  private func rows(_ blocks: [ChatMarkdownBlock]) -> [[ChatMarkdownBlock]] {
    var rows: [[ChatMarkdownBlock]] = []
    for block in blocks {
      let row = block.components.dropFirst().first?.identity
      if let row, rows.last?.last?.components.dropFirst().first?.identity == row { rows[rows.count - 1].append(block) }
      else { rows.append([block]) }
    }
    return rows
  }

  @ViewBuilder private func blockView(_ block: ChatMarkdownBlock) -> some View {
    let code = block.components.contains { if case .codeBlock = $0.kind { return true }; return false }
    let quote = block.components.contains { $0.kind == .blockQuote }
    let depth = block.components.filter { if case .listItem = $0.kind { return true }; return false }.count
    HStack(alignment: .top, spacing: 8) {
      if quote { RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.4)).frame(width: 3) }
      if let item = block.components.first(where: { if case .listItem = $0.kind { return true }; return false }),
         case .listItem(let ordinal) = item.kind {
        let ordered = block.components.drop(while: { $0.identity != item.identity }).dropFirst().first?.kind == .orderedList
        Text(ordered ? "\(ordinal)." : "•").foregroundStyle(.secondary)
      }
      if code {
        ScrollView(.horizontal) {
          Text(verbatim: String(block.text.characters)).font(.system(size: 13, design: .monospaced)).padding(12)
        }.background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
      } else {
        Text(block.text).font(blockFont(block)).frame(maxWidth: .infinity, alignment: .leading)
      }
    }.padding(.leading, CGFloat(max(0, depth - 1)) * 18).fixedSize(horizontal: false, vertical: true)
  }

  private func blockFont(_ block: ChatMarkdownBlock) -> Font {
    for component in block.components {
      if case .header(let level) = component.kind { return .system(size: CGFloat(max(15, 24 - level * 2)), weight: .semibold) }
    }
    return ChatTypography.body
  }
}
