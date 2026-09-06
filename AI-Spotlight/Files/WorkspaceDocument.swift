import AppKit

/// Converts document bytes after WorkspaceAccess has authorized and read them. This layer never
/// opens URLs or external resources; both agents edit the same decoded text and journal raw bytes.
enum WorkspaceDocument {
  static func isRTF(path: String, data: Data? = nil) -> Bool {
    (path as NSString).pathExtension.lowercased() == "rtf" || data?.starts(with: Data(#"{\rtf"#.utf8)) == true
  }

  static func text(path: String, data: Data) throws -> String {
    if isRTF(path: path, data: data) { return try richText(data, editing: false).0.string }
    guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
      throw FileModeError.operation("This file is not supported text. Choose a text export to work with it.")
    }
    return text
  }

  static func create(path: String, content: String) throws -> Data {
    try validateContent(content)
    if isRTF(path: path) {
      return try encode(NSAttributedString(string: content), attributes: [:])
    }
    return Data(content.utf8)
  }

  static func edit(path: String, data: Data, oldText: String? = nil, content: String) throws -> Data {
    try validateContent(content)
    if isRTF(path: path, data: data) {
      let (document, attributes) = try richText(data, editing: true)
      let original = document.string
      let range: NSRange
      let replacement: String
      if let oldText {
        range = try uniqueRange(oldText, in: original)
        replacement = content
      } else {
        if original == content { return data }
        // Full replacements preserve unchanged leading/trailing formatting. Prefer targeted
        // patches for separate edits; replacement text inherits the style at the changed range.
        let prefix = zip(original, content).prefix { $0 == $1 }.count
        let suffix = zip(original.dropFirst(prefix).reversed(), content.dropFirst(prefix).reversed())
          .prefix { $0 == $1 }.count
        let start = original.index(original.startIndex, offsetBy: prefix)
        let end = original.index(original.endIndex, offsetBy: -suffix)
        range = NSRange(start..<end, in: original)
        replacement = String(content.dropFirst(prefix).dropLast(suffix))
      }
      if (original as NSString).substring(with: range) == replacement { return data }
      document.replaceCharacters(in: range, with: replacement)
      return try encode(document, attributes: attributes)
    }
    let original = try text(path: path, data: data)
    if let oldText {
      let range = try uniqueRange(oldText, in: original)
      return Data((original as NSString).replacingCharacters(in: range, with: content).utf8)
    }
    return Data(content.utf8)
  }

  private static func validateContent(_ content: String) throws {
    guard content.utf8.count <= WorkspaceAccess.fileLimit else { throw FileModeError.tooLarge }
    guard !content.utf8.contains(0) else { throw FileModeError.invalidArguments }
  }

  private static func uniqueRange(_ old: String, in text: String) throws -> NSRange {
    let value = text as NSString
    let first = value.range(of: old, options: .literal)
    guard !old.isEmpty, first.location != NSNotFound else { throw FileModeError.invalidArguments }
    let rest = NSRange(location: first.location + 1, length: value.length - first.location - 1)
    guard value.range(of: old, options: .literal, range: rest).location == NSNotFound else {
      throw FileModeError.invalidArguments
    }
    return first
  }

  private static func richText(_ data: Data, editing: Bool) throws
    -> (NSMutableAttributedString, [NSAttributedString.DocumentAttributeKey: Any]) {
    guard data.count <= WorkspaceAccess.fileLimit else { throw FileModeError.tooLarge }
    guard data.starts(with: Data(#"{\rtf"#.utf8)) else {
      throw FileModeError.operation("This RTF file is not valid rich text. Open and save it in TextEdit before trying again.")
    }
    // Cocoa's RTF exporter omits attachments. Do not discard images, embedded objects or
    // dynamic fields that a text-only edit cannot faithfully round-trip.
    if editing && String(decoding: data, as: UTF8.self)
      .range(of: #"\\(pict|object|objdata|shp|field|trowd)\b"#, options: .regularExpression) != nil {
      throw FileModeError.operation("This RTF contains embedded content or a complex layout that File Mode cannot preserve. Use a text-only copy to edit it.")
    }
    var attributes: NSDictionary?
    guard let document = NSMutableAttributedString(rtf: data, documentAttributes: &attributes) else {
      throw FileModeError.operation("This RTF file could not be read. Open and save it in TextEdit before trying again.")
    }
    guard document.string.utf8.count <= WorkspaceAccess.fileLimit else { throw FileModeError.tooLarge }
    return (document, attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:])
  }

  private static func encode(_ document: NSAttributedString,
                             attributes: [NSAttributedString.DocumentAttributeKey: Any]) throws -> Data {
    guard let data = document.rtf(from: NSRange(location: 0, length: document.length), documentAttributes: attributes),
          data.count <= WorkspaceAccess.fileLimit else { throw FileModeError.tooLarge }
    // Reject serializer failures before the workspace snapshot/write transaction starts.
    guard try richText(data, editing: false).0.string == document.string else {
      throw FileModeError.operation("The RTF edit could not be saved faithfully. The original file has been kept.")
    }
    return data
  }
}
