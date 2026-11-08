import CoreML
import Foundation
import FluidAudio
import KlavkoCore

/// Cohere Transcribe speech recognition on this Mac (Core ML), via FluidAudio. Better than Parakeet at English
/// spoken with an accent, but it knows only 14 languages (no Ukrainian or Russian) and must be told the language,
/// so Klavko uses it only for voice input in one language, by that language's own hotkey.
/// The model (~2.2 GB) is downloaded once from Hugging Face; after that everything runs offline.
@MainActor
final class CohereEngine: ObservableObject {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State

    private var models: CoherePipeline.LoadedModels?
    private var loading: Task<CoherePipeline.LoadedModels, Error>?
    private let pipeline = CoherePipeline()
    /// Frees the memory after a while without dictation.
    private var unloadTimer: Timer?

    /// The languages it recognizes ("en", "de", "fr"…).
    static let languages = Set(CohereAsrConfig.Language.allCases.map(\.rawValue))

    private static var modelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    private static var directory: URL {
        modelsRoot.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName, isDirectory: true)
    }

    private static var modelsExist: Bool {
        ModelNames.CohereTranscribe.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    init() {
        state = Self.modelsExist ? .ready : .notDownloaded
    }

    var isDownloaded: Bool { state == .ready }

    /// Downloads (if needed) and loads the model; cheap if it's already loaded.
    @discardableResult
    func prepare() -> Task<CoherePipeline.LoadedModels, Error> {
        unloadTimer?.invalidate()
        if let models { return Task { models } }
        if let loading { return loading }
        let task = Task { [weak self] () throws -> CoherePipeline.LoadedModels in
            let downloading = !Self.modelsExist
            if downloading {
                try await ModelHub.download(.cohereTranscribeCoreml, to: Self.modelsRoot) { progress in
                    // A download alone reports up to half: the other half is for compiling, done elsewhere.
                    let fraction = min(1, progress.fractionCompleted * 2)
                    Task { @MainActor in
                        if self?.state != .ready { self?.state = .downloading(fraction) }
                    }
                }
            }
            if downloading { await MainActor.run { self?.state = .downloading(1) } }
            let directory = Self.directory
            // The Neural Engine alone: macOS prepares the model for it once (about a minute) and keeps that, so later
            // launches load it in a moment. With the GPU too, every launch spent two minutes on the first recording.
            let models = try await CoherePipeline.loadModels(encoderDir: directory, decoderDir: directory, vocabDir: directory,
                                                             computeUnits: .cpuAndNeuralEngine)
            // The first recognition after loading is slow (a minute right after the download, some seconds later):
            // it is done now, on a second of silence, while the user is still speaking.
            if let pipeline = self?.pipeline {
                _ = try? await pipeline.transcribe(audio: [Float](repeating: 0, count: CohereAsrConfig.sampleRate),
                                                   models: models)
            }
            return models
        }
        loading = task
        Task { [weak self] in
            do {
                let models = try await task.value
                self?.models = models
                self?.state = .ready
                Log.engine.notice("Cohere model ready")
            } catch {
                self?.state = Self.modelsExist ? .ready : .failed(error.localizedDescription)
                Log.engine.error("Cohere model failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.loading = nil
        }
        return task
    }

    /// Text of a recording in `language` (one of `languages`). Long recordings go in pieces of up to 20 s,
    /// cut in pauses: the model takes 35 s at most and stops after about a hundred tokens.
    func transcribe(file: URL, language code: String) async throws -> String {
        guard let language = CohereAsrConfig.Language(rawValue: code) else { return "" }
        let models = try await prepare().value
        let samples = try AudioConverter().resampleAudioFile(file)
        var pieces: [String] = []
        for range in AudioChunks.split(samples, sampleRate: CohereAsrConfig.sampleRate) {
            let result = try await pipeline.transcribe(audio: Array(samples[range]), models: models, language: language)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pieces.append(text) }
        }
        scheduleUnload()
        return TranscriptCleanup.clean(pieces.joined(separator: " "))
    }

    /// Deletes the downloaded model.
    func remove() {
        guard loading == nil else { return }
        unloadTimer?.invalidate()
        models = nil
        try? FileManager.default.removeItem(at: Self.directory)
        state = .notDownloaded
    }

    private func scheduleUnload() {
        unloadTimer?.invalidate()
        unloadTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.loading == nil, self.models != nil else { return }
                self.models = nil
                Log.engine.notice("Cohere model unloaded after 10 min idle")
            }
        }
    }
}
