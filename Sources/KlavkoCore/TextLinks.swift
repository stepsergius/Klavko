import Foundation

/// Web and mail addresses inside text ("see https://example.com or write to a@b.ua"), as the system finds them.
public enum TextLinks {
    public struct Found: Equatable, Sendable {
        /// Where the address is in the text.
        public let range: Range<String.Index>
        public let url: URL
    }

    public static func find(in text: String) -> [Found] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: whole).compactMap { match in
            guard let url = match.url, let range = Range(match.range, in: text) else { return nil }
            return Found(range: range, url: url)
        }
    }
}
