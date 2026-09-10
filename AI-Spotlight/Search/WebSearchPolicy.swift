import Foundation

/// A local freshness policy, independent of model routing and evidence capacity.
/// Inspect only the user's question: quoted material, history, files and OCR do
/// not get to opt a request into network access.
enum WebSearchPolicy {
  static func needsFreshInformation(_ prompt: String, now: Date = Date()) -> Bool {
    let text = questionText(prompt)
    guard !text.isEmpty, !matches(optOut, text) else { return false }
    if LocationIntent.needsLocation(prompt) { return true }
    return needsFreshFacts(text, now: now)
  }

  static func questionText(_ prompt: String) -> String {
    let question = ThinkCommand.message(prompt).content
    return literalMaterial.stringByReplacingMatches(in: question,
      range: NSRange(question.startIndex..., in: question),
      withTemplate: " ")
      .replacingOccurrences(of: "’", with: "'")
      .lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  static func isOfflineOrTransformation(_ text: String) -> Bool {
    matches(optOut, text) || matches(transformation, text) || matches(localTask, text)
  }

  private static func needsFreshFacts(_ text: String, now: Date) -> Bool {
    if matches(explicitLookup, text) { return true }
    guard !matches(transformation, text), !matches(localTask, text) else { return false }

    if matches(recentDevelopments, text) { return true }
    let asksForFacts = matches(factualRequest, text)
    if asksForFacts && matches(recency, text) { return true }
    let year = Calendar(identifier: .gregorian).component(.year, from: now)
    let years = text.split(whereSeparator: { !$0.isNumber }).compactMap { part -> Int? in
      guard part.count == 4, let value = Int(part), (1000...2999).contains(value) else { return nil }
      return value
    }
    let historical = years.contains { $0 < year - 1 } || matches(historicalTopic, text)
    if !historical && !matches(conceptualQuestion, text) && matches(changingFact, text) { return true }

    // A year alone is not a freshness signal (arithmetic and historical questions
    // stay local). Current/recent event queries can omit words such as "latest".
    let hasRecentYear = (year - 1...year + 1).contains { value in
      text.range(of: "\\b\(value)\\b", options: .regularExpression) != nil
    }
    return hasRecentYear && asksForFacts && matches(eventTopic, text)
  }

  private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
    pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  private static func expression(_ pattern: String) -> NSRegularExpression {
    // All patterns are fixed, tested source literals, never user-provided regexes.
    try! NSRegularExpression(pattern: pattern)
  }

  private static let literalMaterial = expression(#"(?s)```.*?(?:```|$)|`[^`]*(?:`|$)|"[^"\n]*(?:"|$)|“[^”]*(?:”|$)"#)
  private static let optOut = expression(#"\b(?:(?:do not|don't|dont|never) (?:\w+ ){0,3}(?:search|browse|look up|use (?:the )?(?:web|internet))|(?:without|no) (?:\w+ ){0,2}(?:web|internet|browsing|search)|(?:stay|answer|respond|keep (?:this|it)) offline|(?:use|using|from) (?:only )?(?:your (?:own |existing )?knowledge|memory only))\b"#)
  private static let explicitLookup = expression(#"^(?:(?:please|can you|could you) )?(?:search|browse|check|look up|find|verify)\b.{0,60}\b(?:web|internet|online)\b"#)
  private static let transformation = expression(#"^(?:(?:please|can you|could you|help me) )?(?:translate|rewrite|rephrase|proofread|paraphrase|(?:write|draft|compose) (?:(?:a|an|me|a short|a new) )?(?:poem|story|email|message|letter|function|script|test)|invent|imagine|roleplay|pretend|debug|refactor|implement|fix (?:this|my|the) (?:code|function|test)|summari[sz]e (?:this|the following|the attached|my))\b"#)
  private static let localTask = expression(#"\b(?:current|latest|recent) (?:file|folder|directory|selection|function|variable|branch|commit|diff|log|chat|conversation|document|draft|code|buffer|working directory)\b"#)
  private static let factualRequest = expression(#"\b(?:what|who|when|where|which|how|is|are|has|have|did|does|do|can|could|tell me|give me|show me|find|check|compare|summari[sz]e|explain|list|write|update me)\b"#)
  private static let recency = expression(#"\b(?:latest|recent|recently|newest|breaking|currently|today|yesterday|tonight|tomorrow|right now|up[- ]to[- ]date|this (?:week|month|year|season)|(?:past|last) (?:night|weekend|week|month|year|\d+ (?:hours|days|weeks))|current (?!in\b|through\b|flow\b|flows\b|density\b|account\b|assets\b|liabilities\b))\b"#)
  private static let recentDevelopments = expression(#"\b(?:(?:latest|recent|breaking|today'?s|current|new|upcoming) (?:\w+ ){0,3}(?:news|headlines|updates|developments|events|research|studies|announcements|releases|products)|(?:news|headlines|updates) (?:about|on|from|in|for)|what'?s (?:new|happening|going on)|what is (?:new|happening|going on))\b"#)
  private static let changingFact = expression(#"\b(?:(?:who (?:is|'s)|who's) (?:the )?(?:president|prime minister|ceo|governor|mayor|leader|champion)\b|(?:weather|forecast) (?:in|for|at)\b|(?:will it|is it going to) (?:rain|snow)\b|(?:stock|share|bitcoin|btc|ethereum|eth) price\b|(?:price|value) of (?:bitcoin|btc|ethereum|eth)\b|(?:exchange|mortgage) rates?\b|(?:who (?:won|is winning)|score (?:of|in)|scores? for)\b|(?:when (?:is|does)|what time (?:is|does))\b.{0,60}\b(?:next|play|start|open|close|release)\b|(?:is|are)\b.{0,50}\b(?:open now|still available|in stock)\b)"#)
  private static let historicalTopic = expression(#"\b(?:world war|ancient|medieval|roman empire|historical|history of)\b"#)
  private static let conceptualQuestion = expression(#"\b(?:what (?:is|are)|define|explain|how (?:does|do)) (?:a |an |the concept of )?(?:weather|stock prices?|share prices?|exchange rates?|mortgage rates?)(?: work| mean| change| fluctuate)?[?.!]*$"#)
  private static let eventTopic = expression(#"\b(?:election|elections|results|winner|winners|release|releases|announcements|conference|summit|wwdc|schedule|standings|season|tournament|olympics|world cup|budget|laws|regulations)\b"#)
}
