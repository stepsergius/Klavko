import AppKit
import KlavkoCore
import ScreenCaptureKit
import Vision

/// The lines of text in a window, read from the screen on this Mac (Vision), and where each letter of them is.
/// For apps that draw their text themselves (Google Docs): Accessibility tells what the text is, not where.
/// Only that window is taken (not Klavko's underlines over it); the picture stays in memory and is dropped.
struct ScreenLines: Sendable {
    struct Line: Sendable {
        let text: String
        /// Where the line's characters are, in AppKit screen coordinates: index → rectangle.
        let boxes: @Sendable (Range<Int>) -> NSRect?
    }

    let lines: [Line]

    /// Where `range` of `paragraph` (UTF-16 units) is on screen: one rectangle a line.
    func rects(of range: Range<Int>, in paragraph: String) -> [NSRect] {
        ScreenTextAlignment.spots(of: range, in: paragraph, lines: lines.map(\.text)).compactMap { spot in
            lines[spot.line].boxes(spot.characters)
        }
    }

    /// Reads the window of app `pid` that has `frame` (AppKit coordinates). Nil without the Screen Recording
    /// permission or when the window can't be taken.
    static func read(window frame: NSRect, of pid: pid_t, languages: [String]) async -> ScreenLines? {
        guard CGPreflightScreenCaptureAccess(),
              let mainHeight = NSScreen.screens.first?.frame.height,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        // ScreenCaptureKit counts from the top of the main screen, as Accessibility does.
        let topFrame = CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
        guard let window = content.windows
            .filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.intersects(topFrame) })
            .max(by: { $0.frame.intersection(topFrame).area < $1.frame.intersection(topFrame).area }) else { return nil }
        let scale = NSScreen.screens.first { $0.frame.intersects(frame) }?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration) else { return nil }
        let shown = NSRect(x: window.frame.minX, y: mainHeight - window.frame.maxY, width: window.frame.width,
                           height: window.frame.height)
        return await Task.detached(priority: .userInitiated) { recognize(image, shownAt: shown, languages: languages) }.value
    }

    private static func recognize(_ image: CGImage, shownAt shown: NSRect, languages: [String]) -> ScreenLines? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // As written, mistakes and all: the letters are lined up with the real text, not corrected.
        request.usesLanguageCorrection = false
        if !languages.isEmpty { request.recognitionLanguages = languages }
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil, let observations = request.results else {
            return nil
        }
        let lines = observations.compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
            return Line(text: text, boxes: { characters in
                guard let start = text.index(text.startIndex, offsetBy: characters.lowerBound, limitedBy: text.endIndex),
                      let end = text.index(text.startIndex, offsetBy: characters.upperBound, limitedBy: text.endIndex),
                      let box = try? candidate.boundingBox(for: start..<end)?.boundingBox else { return nil }
                // Vision's boxes are parts of the picture from its bottom left.
                return NSRect(x: shown.minX + box.minX * shown.width, y: shown.minY + box.minY * shown.height,
                              width: box.width * shown.width, height: box.height * shown.height)
            })
        }
        return ScreenLines(lines: lines)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
