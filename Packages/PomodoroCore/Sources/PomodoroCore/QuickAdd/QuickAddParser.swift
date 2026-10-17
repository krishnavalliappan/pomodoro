import Foundation

/// Parses `Write spec ~3 @14:00 45m #work tomorrow` into a `QuickAddResult`.
///
/// Tokens are whitespace-separated and order-independent. The first token of each kind
/// wins; later ones of the same kind are still removed from the title. Anything that
/// isn't a valid token stays in the title, and a leading `\` makes a token literal.
public struct QuickAddParser: Sendable {
    public var calendar: Calendar
    public var pomodoroLength: TimeInterval
    public var defaultBlockDuration: TimeInterval

    public init(
        calendar: Calendar = .current,
        pomodoroLength: TimeInterval = 25 * 60,
        defaultBlockDuration: TimeInterval = 30 * 60
    ) {
        self.calendar = calendar
        self.pomodoroLength = pomodoroLength
        self.defaultBlockDuration = defaultBlockDuration
    }

    public func parse(_ input: String, now: Date) -> QuickAddResult {
        var titleWords: [Substring] = []
        var estimate: Int?
        var tag: String?
        var dayOffset: Int?
        var time: (hour: Int, minute: Int)?
        var duration: TimeInterval?

        for word in input.split(whereSeparator: \.isWhitespace) {
            if word.first == "\\" {
                let rest = word.dropFirst()
                let escapable = rest.first.map { "#~@".contains($0) } ?? false
                titleWords.append(escapable || token(rest, now: now) != nil ? rest : word)
                continue
            }
            switch token(word, now: now) {
            case .estimate(let n): estimate = estimate ?? n
            case .tag(let t): tag = tag ?? t
            case .day(let offset): dayOffset = dayOffset ?? offset
            case .time(let h, let m): time = time ?? (hour: h, minute: m)
            case .duration(let d): duration = duration ?? d
            case nil: titleWords.append(word)
            }
        }

        let today = calendar.startOfDay(for: now)
        var day = dayOffset
            .flatMap { calendar.date(byAdding: .day, value: $0, to: today) }
            .map { calendar.startOfDay(for: $0) }

        var blockStart: Date?
        if let time {
            let base = day ?? today
            // A wall-clock time skipped by DST snaps to the end of the gap (02:30 → 03:00);
            // a repeated one resolves to its first occurrence.
            blockStart = calendar.date(
                bySettingHour: time.hour, minute: time.minute, second: 0, of: base,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first
            )
            day = base
        }

        if blockStart != nil, duration == nil {
            duration = estimate.map { Double($0) * pomodoroLength } ?? defaultBlockDuration
        }

        return QuickAddResult(
            title: titleWords.joined(separator: " "),
            estimate: estimate,
            tag: tag,
            day: day,
            blockStart: blockStart,
            blockDuration: duration
        )
    }

    private enum Token {
        case estimate(Int)
        case tag(String)
        case day(offset: Int)
        case time(hour: Int, minute: Int)
        case duration(TimeInterval)
    }

    private func token(_ word: Substring, now: Date) -> Token? {
        switch word.first {
        case "~": return Self.estimate(word.dropFirst()).map(Token.estimate)
        case "#": return Self.tag(word.dropFirst()).map(Token.tag)
        case "@": return Self.time(word.dropFirst()).map { Token.time(hour: $0.hour, minute: $0.minute) }
        default:
            if let minutes = Self.durationMinutes(word) { return .duration(TimeInterval(minutes * 60)) }
            return dayOffset(word, now: now).map { Token.day(offset: $0) }
        }
    }

    private static func estimate(_ body: Substring) -> Int? {
        guard body.count <= 2, isDigits(body), let n = Int(body), n > 0 else { return nil }
        return n
    }

    private static func tag(_ body: Substring) -> String? {
        let allowed = body.allSatisfy { $0.isLetter || $0.isNumber || "_-/".contains($0) }
        return !body.isEmpty && allowed ? String(body) : nil
    }

    private static func time(_ body: Substring) -> (hour: Int, minute: Int)? {
        var body = Substring(body.lowercased())
        var meridiem: Substring?
        if body.hasSuffix("am") || body.hasSuffix("pm") {
            meridiem = body.suffix(2)
            body = body.dropLast(2)
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              (1...2).contains(parts[0].count), isDigits(parts[0]), var hour = Int(parts[0])
        else { return nil }
        var minute = 0
        if parts.count == 2 {
            guard parts[1].count == 2, isDigits(parts[1]), let m = Int(parts[1]), m < 60 else { return nil }
            minute = m
        }
        switch meridiem {
        case nil:
            guard hour < 24 else { return nil }
        case let suffix?:
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (suffix == "pm" ? 12 : 0)
        }
        return (hour, minute)
    }

    /// `45m`, `2h`, or `1h30m`, capped at one day.
    private static func durationMinutes(_ word: Substring) -> Int? {
        let word = Substring(word.lowercased())
        var hours = 0
        var rest = word
        if let h = word.firstIndex(of: "h") {
            let digits = word[..<h]
            guard digits.count <= 2, isDigits(digits), let value = Int(digits) else { return nil }
            hours = value
            rest = word[word.index(after: h)...]
        }
        var minutes = 0
        if !rest.isEmpty {
            guard rest.hasSuffix("m") else { return nil }
            let digits = rest.dropLast()
            guard digits.count <= 4, isDigits(digits), let value = Int(digits) else { return nil }
            minutes = value
        } else if hours == 0 {
            return nil
        }
        let total = hours * 60 + minutes
        return (1...24 * 60).contains(total) ? total : nil
    }

    private static let englishWeekdays = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    ]

    /// Days from today. A weekday name means its next occurrence, today included.
    private func dayOffset(_ word: Substring, now: Date) -> Int? {
        let folded = fold(word)
        switch folded {
        case "today": return 0
        case "tomorrow": return 1
        default: break
        }
        let localized = calendar.weekdaySymbols.map { fold($0[...]) }
        let index = Self.englishWeekdays.firstIndex(of: folded) ?? localized.firstIndex(of: folded)
        guard let index else { return nil }
        let current = calendar.component(.weekday, from: now) - 1
        return (index - current + 7) % 7
    }

    private func fold(_ word: Substring) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: calendar.locale)
    }

    private static func isDigits(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
