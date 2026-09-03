import Foundation

/// Lightweight port of training `_slot_repair.py` / Android `SlotRepair`.
enum SlotRepair {
    static func repair(
        raw: String,
        utterance: String,
        tool: String,
        action: String
    ) -> ToolCall? {
        guard !tool.isEmpty else { return nil }
        if tool == "no_match" {
            return ToolCall(name: "no_match", arguments: [:])
        }

        let parsed = LfmToolCallParser.parse(raw)
        var params = parsed?.arguments ?? [:]
        params = sanitizeParams(tool: tool, action: action, params: params)
        params = dropNoneLike(params)
        params = repairNumericParams(tool: tool, action: action, params: params, utterance: utterance)
        params = repairStringParams(tool: tool, action: action, params: params, utterance: utterance)
        params = sanitizeParams(tool: tool, action: action, params: params)
        params = dropNoneLike(params)
        params = fillSeekRelativeDefault(tool: tool, action: action, params: params, utterance: utterance)

        var arguments = params
        if !action.isEmpty {
            arguments["action"] = action
        }
        return ToolCall(name: tool, arguments: arguments)
    }

    static func collapseRepetition(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var previous: String?
        var out = text
        while previous != out {
            previous = out
            out = replace(wordRepeatRegex, in: out, with: "$1")
            out = replace(threeWordRepeatRegex, in: out, with: "$1")
            out = replace(twoWordRepeatRegex, in: out, with: "$1")
        }
        return out
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    private static let stringKeys: Set<String> = [
        "episode", "podcast", "title", "ref", "query", "request", "value",
        "timeframe", "tier", "sort_order", "mode", "slot", "target_tool", "target_action",
        "period",
    ]

    // Must cover every (tool, action) ToolCallMapper / ToolSchema can dispatch so
    // sanitizeParams does not strip legitimate generated slots.
    private static let actionParams: [String: [String: Set<String>]] = [
        "playback": [
            "pause": [],
            "resume": [],
            "seek_relative": ["delta_seconds"],
            "seek_to": ["position_seconds"],
            "next_episode": [],
        ],
        "effects": [
            "set_speed": ["speed"],
            "adjust_speed": ["delta"],
            "set_trim_mode": ["mode"],
            "set_volume_boost": ["enabled"],
            "query": [],
        ],
        "volume": [
            "set_volume": ["volume"],
            "adjust_volume": ["delta"],
            "query": [],
        ],
        "sleep": [
            "set": ["minutes"],
            "end_of_episode": [],
            "end_of_chapter": [],
            "add_time": ["minutes"],
            "cancel": [],
            "query": [],
        ],
        "chapter": [
            "next": [],
            "previous": [],
            "by_index": ["index"],
            "by_title": ["query"],
            "open_link": ["index", "query"],
            "query_list": [],
            "query_current": [],
            "query_count": [],
            "query_next": [],
        ],
        "bookmark": [
            "add": ["title"],
            "rename": ["ref", "title"],
            "play": ["ref"],
            "delete": ["ref"],
            "delete_all": [],
            "query_list": [],
            "query_count": [],
            "query_nearby": [],
        ],
        "queue": [
            "add_top": ["episode"],
            "add_bottom": ["episode"],
            "remove": ["episode"],
            "move_to_top": ["episode"],
            "move_to_bottom": ["episode"],
            "clear": [],
            "remove_by_podcast": ["podcast"],
            "sort": ["sort_order"],
            "query_contents": [],
            "query_next": [],
            "query_length": [],
            "query_is_queued": ["episode"],
        ],
        "playback_query": [
            "whats_playing": [],
            "position": [],
            "time_remaining": [],
            "current_podcast": [],
            "episode_duration": [],
            "publish_date": [],
            "episode_description": [],
            "download_status": [],
            "episode_title": [],
        ],
        "stats_query": [
            "listening_time": ["period"],
            "top_podcasts": ["period"],
            "episodes_finished": ["period"],
            "listening_streak": [],
            "subscription_count": [],
            "unplayed_total": [],
            "download_stats": [],
            "queue_total": [],
            "new_episodes": ["timeframe"],
            "time_since_last_listen": [],
        ],
        "cloud_route": [
            "route": ["request", "tier"],
        ],
        "dialog_control": [
            "begin": ["target_tool", "target_action"],
            "provide_slot": ["target_tool", "target_action", "slot", "value"],
            "confirm": [],
            "deny": [],
            "cancel": [],
            "new_command": ["value"],
        ],
        "no_match": [
            "": [],
        ],
    ]

    private static func allowedParams(tool: String, action: String) -> Set<String> {
        actionParams[tool]?[action] ?? []
    }

    private static func sanitizeParams(
        tool: String,
        action: String,
        params: [String: Any]
    ) -> [String: Any] {
        let allowed = allowedParams(tool: tool, action: action)
        return params.filter { allowed.contains($0.key) }
    }

    private static func dropNoneLike(_ params: [String: Any]) -> [String: Any] {
        params.filter { _, value in
            if let string = value as? String {
                return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && string.compare("none", options: .caseInsensitive) != .orderedSame
            }
            return true
        }
    }

    private static func repairNumericParams(
        tool: String,
        action: String,
        params: [String: Any],
        utterance: String
    ) -> [String: Any] {
        let allowed = allowedParams(tool: tool, action: action)
        var out = params
        for (key, value) in extractNumericSlots(tool: tool, action: action, utterance: utterance) {
            if allowed.contains(key) {
                out[key] = value
            }
        }
        return out
    }

    private static func extractNumericSlots(
        tool: String,
        action: String,
        utterance: String
    ) -> [String: Any] {
        let allowed = allowedParams(tool: tool, action: action)
        var out: [String: Any] = [:]
        if allowed.contains("delta_seconds"), let delta = extractDeltaSeconds(utterance) {
            out["delta_seconds"] = delta
        }
        return out
    }

    /// When the model omits delta_seconds, fill a signed ±30s default from wording.
    private static func fillSeekRelativeDefault(
        tool: String,
        action: String,
        params: [String: Any],
        utterance: String
    ) -> [String: Any] {
        guard tool == "playback", action == "seek_relative" else { return params }
        if params["delta_seconds"] != nil { return params }
        var out = params
        let lower = utterance.lowercased()
        let isBack = backRegex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil
        out["delta_seconds"] = isBack ? -defaultSkipSeconds : defaultSkipSeconds
        return out
    }

    private static func extractDeltaSeconds(_ utterance: String) -> Int? {
        let lower = utterance.lowercased()
        let pairs = durationPairs(utterance)
        let seconds: Int
        if pairs.isEmpty, aMinuteRegex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
            seconds = 60
        } else if let fromPairs = secondsFromPairs(pairs) {
            seconds = fromPairs
        } else {
            return nil
        }
        if backRegex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
            return -seconds
        }
        return seconds
    }

    private static func durationPairs(_ utterance: String) -> [(NSNumber, String)] {
        var pairs: [(NSNumber, String)] = []
        let nsRange = NSRange(utterance.startIndex..., in: utterance)
        numberRegex.enumerateMatches(in: utterance, options: [], range: nsRange) { match, _, _ in
            guard let match, let numberRange = Range(match.range, in: utterance) else { return }
            let numberText = String(utterance[numberRange])
            guard let value = parseNumberPhrase(numberText) else { return }
            let afterNumber = match.range.location + match.range.length
            let unitSearch = NSRange(location: afterNumber, length: utterance.utf16.count - afterNumber)
            guard let unitMatch = unitRegex.firstMatch(in: utterance, options: [], range: unitSearch),
                  unitMatch.range.location == afterNumber,
                  let unitRange = Range(unitMatch.range(at: 1), in: utterance)
            else { return }
            pairs.append((value, String(utterance[unitRange]).lowercased()))
        }
        return pairs
    }

    private static func secondsFromPairs(_ pairs: [(NSNumber, String)]) -> Int? {
        guard !pairs.isEmpty else { return nil }
        var total = 0.0
        for (value, unit) in pairs {
            total += toSeconds(value.doubleValue, unit: unit)
        }
        return Int(total)
    }

    private static func toSeconds(_ value: Double, unit: String) -> Double {
        if unit.hasPrefix("hour") || unit == "hr" || unit == "hrs" {
            return value * 3600
        }
        if unit.hasPrefix("min") {
            return value * 60
        }
        return value
    }

    private static func parseNumberPhrase(_ text: String) -> NSNumber? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
        if let int = Int(raw) { return NSNumber(value: int) }
        if let double = Double(raw) { return NSNumber(value: double) }
        let parts = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.count == 2, let tens = tensMap[parts[0]], let ones = ones1to9[parts[1]] {
            return NSNumber(value: tens + ones)
        }
        guard parts.count == 1, let ones = onesMap[parts[0]] else { return nil }
        return NSNumber(value: ones)
    }

    private static let onesMap: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let ones1to9: [String: Int] = onesMap.filter {
        ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"].contains($0.key)
    }
    private static let tensMap: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static func repairStringParams(
        tool: String,
        action: String,
        params: [String: Any],
        utterance: String
    ) -> [String: Any] {
        let quotes = quotedSpans(utterance)
        let allowed = allowedParams(tool: tool, action: action)
        var out = params
        if action == "provide_slot", allowed.contains("value") {
            repairProvideSlotValue(&out, utterance: utterance, quotes: quotes)
        }
        for key in Array(out.keys) {
            guard stringKeys.contains(key), let value = out[key] as? String else { continue }
            if let repaired = repairOneString(key: key, value: value, utterance: utterance, quotes: quotes) {
                out[key] = repaired
            }
        }
        return out
    }

    private static func repairProvideSlotValue(
        _ params: inout [String: Any],
        utterance: String,
        quotes: [String]
    ) {
        switch params["slot"] as? String {
        case "title":
            if let quote = quotes.last {
                params["value"] = quote
            } else {
                let cleaned = utterance
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".?! "))
                if !cleaned.isEmpty {
                    params["value"] = cleaned
                }
            }
        case "ref":
            if thisOneRegex.firstMatch(
                in: utterance,
                range: NSRange(utterance.startIndex..., in: utterance)
            ) != nil {
                params["value"] = "this"
            }
        default:
            break
        }
    }

    private static func repairOneString(
        key: String,
        value: String,
        utterance: String,
        quotes: [String]
    ) -> String? {
        let cleaned = collapseRepetition(value.trimmingCharacters(in: .whitespacesAndNewlines))
        if key == "title", let quote = quotes.last {
            if looksGarbled(cleaned) || isBrokenCopy(cleaned, quote) {
                return quote
            }
        }
        if ["title", "value", "ref"].contains(key), !quotes.isEmpty {
            let quote = quotes.count == 1 ? quotes[0] : quotes.last!
            if isBrokenCopy(cleaned, quote) {
                return quote
            }
        }
        return cleaned != value ? cleaned : nil
    }

    static func quotedSpans(_ utterance: String) -> [String] {
        var spans: [String] = []
        let nsRange = NSRange(utterance.startIndex..., in: utterance)
        doubleQuoteRegex.enumerateMatches(in: utterance, options: [], range: nsRange) { match, _, _ in
            guard let match, let range = Range(match.range(at: 1), in: utterance) else { return }
            spans.append(String(utterance[range]))
        }

        var index = utterance.startIndex
        while index < utterance.endIndex {
            if utterance[index] != "'" {
                index = utterance.index(after: index)
                continue
            }
            let prev = index > utterance.startIndex ? utterance[utterance.index(before: index)] : nil
            let next = utterance.index(after: index) < utterance.endIndex
                ? utterance[utterance.index(after: index)]
                : nil
            if let prev, prev.isLetter, let next, next.isLetter {
                index = utterance.index(after: index)
                continue
            }

            var cursor = utterance.index(after: index)
            var buffer = ""
            var closed = false
            while cursor < utterance.endIndex {
                if utterance[cursor...].lowercased().hasPrefix("'n'") {
                    let end = utterance.index(cursor, offsetBy: 3)
                    buffer += String(utterance[cursor..<end])
                    cursor = end
                    continue
                }
                let char = utterance[cursor]
                if char != "'" {
                    buffer.append(char)
                    cursor = utterance.index(after: cursor)
                    continue
                }
                let prevChar = cursor > utterance.startIndex ? utterance[utterance.index(before: cursor)] : nil
                let nextChar = utterance.index(after: cursor) < utterance.endIndex
                    ? utterance[utterance.index(after: cursor)]
                    : nil
                if prevChar?.lowercased() == "n", nextChar?.lowercased() == "t" {
                    buffer.append("'")
                    cursor = utterance.index(after: cursor)
                    continue
                }
                if let prevChar, prevChar.isLetter, let nextChar, nextChar.isLetter {
                    buffer.append("'")
                    cursor = utterance.index(after: cursor)
                    continue
                }
                if buffer.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 {
                    spans.append(buffer)
                }
                index = utterance.index(after: cursor)
                closed = true
                break
            }
            if !closed { break }
        }
        return spans
    }

    static func looksGarbled(_ value: String?) -> Bool {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.compare("none", options: .caseInsensitive) == .orderedSame
            || text.compare("null", options: .caseInsensitive) == .orderedSame
        {
            return true
        }
        let full = NSRange(text.startIndex..., in: text)
        if waitLoopRegex.firstMatch(in: text, range: full) != nil { return true }
        if wordRepeatRegex.firstMatch(in: text, range: full) != nil { return true }
        let collapsed = collapseRepetition(text)
        return text.count >= 20 && Double(collapsed.count) < Double(text.count) * 0.8
    }

    static func isBrokenCopy(_ pred: String, _ target: String) -> Bool {
        if pred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return false
        }
        let predLower = pred.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let targetLower = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if predLower == targetLower { return false }
        if predLower.count >= 6,
           targetLower.hasPrefix(predLower),
           targetLower.count > predLower.count + 1
        {
            return true
        }
        let ratio = sequenceSimilarity(predLower, targetLower)
        if ratio >= 0.78 { return true }
        if ratio >= 0.62, shareContentToken(predLower, targetLower) { return true }
        return editDistance(predLower, targetLower) <= max(2, targetLower.count / 8)
    }

    private static func shareContentToken(_ left: String, _ right: String) -> Bool {
        let stop: Set<String> = [
            "the", "a", "an", "of", "and", "to", "in", "for", "on",
            "episode", "from", "that", "this",
        ]
        let tokenRegex = try! NSRegularExpression(pattern: #"[A-Za-z0-9']+"#)
        func tokens(_ text: String) -> Set<String> {
            var out = Set<String>()
            let range = NSRange(text.startIndex..., in: text)
            tokenRegex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match, let tokenRange = Range(match.range, in: text) else { return }
                let token = String(text[tokenRange]).lowercased()
                if !stop.contains(token), token.count >= 4 {
                    out.insert(token)
                }
            }
            return out
        }
        return !tokens(left).intersection(tokens(right)).isEmpty
    }

    private static func sequenceSimilarity(_ left: String, _ right: String) -> Double {
        if left == right { return 1.0 }
        let maxLen = max(left.count, right.count)
        if maxLen == 0 { return 1.0 }
        return 1.0 - Double(editDistance(left, right)) / Double(maxLen)
    }

    private static func editDistance(_ left: String, _ right: String) -> Int {
        if left == right { return 0 }
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        let leftChars = Array(left)
        let rightChars = Array(right)
        var prev = Array(0...rightChars.count)
        for i in leftChars.indices {
            var current = Array(repeating: 0, count: rightChars.count + 1)
            current[0] = i + 1
            for j in rightChars.indices {
                let cost = leftChars[i] == rightChars[j] ? 0 : 1
                current[j + 1] = min(
                    prev[j + 1] + 1,
                    current[j] + 1,
                    prev[j] + cost
                )
            }
            prev = current
        }
        return prev[rightChars.count]
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static let wordRepeatRegex = try! NSRegularExpression(
        pattern: #"\b(\w+)(?:[\s,]+\1){2,}\b"#,
        options: [.caseInsensitive]
    )
    private static let threeWordRepeatRegex = try! NSRegularExpression(
        pattern: #"\b(\w+\s+\w+\s+\w+)(?:[\s,]+\1)+\b"#,
        options: [.caseInsensitive]
    )
    private static let twoWordRepeatRegex = try! NSRegularExpression(
        pattern: #"\b(\w+\s+\w+)(?:[\s,]+\1)+\b"#,
        options: [.caseInsensitive]
    )
    private static let aMinuteRegex = try! NSRegularExpression(pattern: #"\ba\s+minute\b"#)
    private static let backRegex = try! NSRegularExpression(pattern: #"\b(back|rewind|behind)\b"#)
    private static let defaultSkipSeconds = 30
    private static let numberRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])(?:\d+(?:\.\d+)?|(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)(?:[-\s](?:one|two|three|four|five|six|seven|eight|nine))?|(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|zero|oh))(?![A-Za-z])"#,
        options: [.caseInsensitive]
    )
    private static let unitRegex = try! NSRegularExpression(
        pattern: #"\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?)\b"#,
        options: [.caseInsensitive]
    )
    private static let thisOneRegex = try! NSRegularExpression(
        pattern: #"\bthis one\b"#,
        options: [.caseInsensitive]
    )
    private static let doubleQuoteRegex = try! NSRegularExpression(pattern: #""([^"]{1,80})""#)
    private static let waitLoopRegex = try! NSRegularExpression(
        pattern: #"\bwait(?:[\s,]+wait){2,}\b"#,
        options: [.caseInsensitive]
    )
}
