import Foundation

/// The selection worked out: an expression ("1 250 * 3 + 15%", "(2,5 + 1) / 2 =") is calculated, with
/// * or × for multiplying and / or ÷ for dividing; any other text with two numbers or more ("Хліб 25, молоко 40")
/// gets their sum, as before.
public enum Calculation {
    public enum Result: Equatable, Sendable {
        case expression(Decimal)
        case sum(Decimal)

        public var value: Decimal {
            switch self {
            case .expression(let value), .sum(let value): value
            }
        }
    }

    public static func of(_ text: String) -> Result? {
        if let value = evaluate(text) { return .expression(value) }
        return QuickText.sum(text).map(Result.sum)
    }

    /// The value of an arithmetic expression; nil when the text isn't one (letters, a lone number, ÷ 0…).
    /// "a + b%" adds b% of a, "a − b%" takes it away; elsewhere "b%" is b/100.
    public static func evaluate(_ text: String) -> Decimal? {
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while source.hasSuffix("=") { source = String(source.dropLast()).trimmingCharacters(in: .whitespaces) }
        // "1 250": thousands with an ordinary space, as people type them.
        while let range = source.range(of: #"(\d) (\d{3})(?!\d)"#, options: .regularExpression) {
            source.replaceSubrange(range, with: source[range].filter { $0 != " " })
        }
        // "2026-11-04", "067-123-45-67": a date or a phone number, not a subtraction.
        if source.range(of: #"^\d+(-\d+){2,}$"#, options: .regularExpression) != nil { return nil }
        guard var tokens = tokenize(source), tokens.contains(where: \.isOperator) else { return nil }
        tokens.append(.end)
        var parser = Parser(tokens: tokens)
        guard let value = parser.expression(), parser.peek == .end else { return nil }
        return value.value
    }

    /// What "=" typed after an expression offers to put after it, as in Apple Notes: "2+3*4" → "14",
    /// "Разом: 1 250 * 3 " → " 3750" (a space after "=" when there's one before it). `line`: the text before the "="
    /// on its line. The decimal mark is the one in the expression, else the usual one in `language`. nil when the line
    /// doesn't end in an expression ("x = 5", "-5", "2026-11-04").
    public static func answer(after line: String, language: String) -> String? {
        let marks = Set(" \u{00A0}\u{202F}+-−–*×·/÷%(),.")
        let tail = Array(line.reversed().prefix { $0.isNumber || marks.contains($0) }.reversed())
        // The expression may start after any space in it ("Також 5, 2+3" → "2+3", "Ціна 25*4"): the longest that
        // works. At the very start, not glued to a word ("x2*3", "a-1").
        let glued = line.dropLast(tail.count).last.map { $0.isLetter || $0 == "_" } ?? false
        var found: (expression: String, value: Decimal)?
        for start in tail.indices where !tail[start].isWhitespace
            && (start == 0 ? !glued : tail[start - 1].isWhitespace) {
            var expression = String(tail[start...]).trimmingCharacters(in: .whitespaces)
            // A list's dash ("- 2+3").
            if expression.hasPrefix("- ") || expression.hasPrefix("– ") { expression.removeFirst(2) }
            // An operator between numbers, not just a sign ("-5").
            let core = expression.drop { "+-−–( ".contains($0) }
            if core.contains(where: { "+-−–*×·/÷".contains($0) }), let value = evaluate(expression) {
                found = (expression, value)
                break
            }
        }
        guard let (expression, value) = found else { return nil }
        let comma: Bool
        if expression.range(of: #"\d,\d"#, options: .regularExpression) != nil, !expression.contains(".") {
            comma = true
        } else if expression.range(of: #"\d\.\d"#, options: .regularExpression) != nil {
            comma = false
        } else {
            comma = !["en", "ja", "zh", "ko"].contains(language)
        }
        return (line.last == " " ? " " : "") + typed(value, comma: comma)
    }

    /// `value` as it's typed: no groups, up to 10 decimals.
    public static func typed(_ value: Decimal, comma: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 10
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.decimalSeparator = comma ? "," : "."
        formatter.minusSign = "-"
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    enum Token: Equatable {
        case number(Decimal), plus, minus, times, divide, percent, open, close, end

        var isOperator: Bool { [.plus, .minus, .times, .divide].contains(self) }
    }

    private static func tokenize(_ text: String) -> [Token]? {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c.isNumber {
                var end = index
                // Digits, with the decimal mark or groups of thousands inside.
                while end < text.endIndex,
                      text[end].isNumber || ([",", ".", "\u{00A0}", "\u{202F}"].contains(text[end])
                                             && text.index(after: end) < text.endIndex && text[text.index(after: end)].isNumber) {
                    end = text.index(after: end)
                }
                guard let number = QuickText.numbers(in: String(text[index..<end])).first,
                      QuickText.numbers(in: String(text[index..<end])).count == 1 else { return nil }
                tokens.append(.number(number < 0 ? -number : number))
                index = end
                continue
            }
            switch c {
            case "+": tokens.append(.plus)
            case "-", "−", "–": tokens.append(.minus)
            case "*", "×", "·": tokens.append(.times)
            case "/", "÷": tokens.append(.divide)
            case "%": tokens.append(.percent)
            case "(": tokens.append(.open)
            case ")": tokens.append(.close)
            case _ where c.isWhitespace: break
            default: return nil
            }
            index = text.index(after: index)
        }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var position = 0

        var peek: Token { tokens[position] }

        mutating func next() -> Token {
            defer { position += 1 }
            return tokens[position]
        }

        /// A value, and whether it was written as a percentage.
        typealias Value = (value: Decimal, percent: Bool)

        mutating func expression() -> Value? {
            guard var left = term() else { return nil }
            while peek == .plus || peek == .minus {
                let adding = next() == .plus
                guard let right = term() else { return nil }
                let amount = right.percent ? left.value * right.value : right.value
                left = (adding ? left.value + amount : left.value - amount, false)
            }
            return left
        }

        mutating func term() -> Value? {
            guard var left = factor() else { return nil }
            while peek == .times || peek == .divide {
                let multiplying = next() == .times
                guard let right = factor() else { return nil }
                if multiplying {
                    left = (left.value * right.value, false)
                } else {
                    guard right.value != 0 else { return nil }
                    left = (left.value / right.value, false)
                }
            }
            return left
        }

        mutating func factor() -> Value? {
            var value: Decimal
            switch next() {
            case .minus:
                guard let inner = factor() else { return nil }
                return (-inner.value, inner.percent)
            case .plus:
                return factor()
            case .number(let number):
                value = number
            case .open:
                guard let inner = expression(), next() == .close else { return nil }
                value = inner.value
            default:
                return nil
            }
            if peek == .percent {
                position += 1
                return (value / 100, true)
            }
            return (value, false)
        }
    }
}
