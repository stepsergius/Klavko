import Foundation

/// Splits a long recording into pieces a speech model can take at once, cutting in the quietest moment
/// (a pause between words) near the end of each piece rather than in the middle of a word.
public enum AudioChunks {
    /// Sample ranges, in order, covering the whole recording. Each is at most `maxSeconds` long; a cut
    /// is looked for in the last `searchSeconds` of a piece.
    public static func split(_ samples: [Float], sampleRate: Int, maxSeconds: Double = 20,
                             searchSeconds: Double = 8) -> [Range<Int>] {
        let maxLength = max(1, Int(maxSeconds * Double(sampleRate)))
        guard samples.count > maxLength else { return [0..<samples.count] }
        let search = min(maxLength - 1, max(1, Int(searchSeconds * Double(sampleRate))))
        let window = max(1, sampleRate / 10)   // 100 ms
        let step = max(1, sampleRate / 50)     // 20 ms
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxLength {
            let from = start + maxLength - search
            let to = start + maxLength - window
            var best = start + maxLength
            var quietest = Float.infinity
            var position = from
            while position <= to {
                var energy: Float = 0
                for index in position..<(position + window) { energy += samples[index] * samples[index] }
                if energy < quietest {
                    quietest = energy
                    best = position + window / 2
                }
                position += step
            }
            ranges.append(start..<best)
            start = best
        }
        ranges.append(start..<samples.count)
        return ranges
    }

    /// Speech is well above this loudness (RMS); a recording that never reaches it is silence or room noise.
    public static let speechLevel: Float = 0.01

    /// The loudness (RMS) of the loudest 100 ms of a recording. A model like Cohere "hears" made-up words in
    /// silence, so a recording below `speechLevel` isn't given to it.
    public static func loudest(_ samples: [Float], sampleRate: Int) -> Float {
        let window = max(1, sampleRate / 10)
        var loudest: Float = 0
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + window)
            var sum: Float = 0
            for index in start..<end { sum += samples[index] * samples[index] }
            loudest = max(loudest, (sum / Float(end - start)).squareRoot())
            start += window
        }
        return loudest
    }
}
