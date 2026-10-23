import Foundation

/// What a QR code holds: a web link to open, or anything else as text to read and copy.
public enum QRContent: Equatable, Sendable {
    case link(URL)
    case text(String)

    /// "https://…" and "www.…" (opened as https) are links; everything else — Wi-Fi settings, contacts,
    /// plain words, other kinds of addresses — is shown as text.
    public init(_ payload: String) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) {
            let candidate = trimmed.lowercased().hasPrefix("www.") ? "https://" + trimmed : trimmed
            if let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
               let host = url.host, host.contains(".") {
                self = .link(url)
                return
            }
        }
        self = .text(payload)
    }
}
