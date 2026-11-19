import Foundation
#if !os(macOS)
import SherpaOnnx
#endif

nonisolated enum LocalTTSClient {
    private enum SynthesisError: Error {
        case missingVoicePack
        case unavailable
        case invalidAudio
    }

    private static let engine = Engine()

    static func synthesize(text: String) async throws -> Data {
        try await engine.synthesize(text)
    }

    static func releaseCachedVoice() async {
        await engine.releaseCachedVoice()
    }

    private actor Engine {
        private var tts: SherpaOnnxOfflineTtsWrapper?
        private var idleReleaseTask: Task<Void, Never>?

        func synthesize(_ text: String) throws -> Data {
            try Task.checkCancellation()
            idleReleaseTask?.cancel()
            defer {
                if tts != nil { scheduleIdleRelease() }
            }
            let voice = try loadVoice()
            // The bundled voice table contains only the Mandarin speaker zf_001.
            let audio = voice.generate(text: text, sid: 0, speed: 0.94)
            try Task.checkCancellation()
            guard audio.n > 0, audio.sampleRate > 0 else { throw SynthesisError.invalidAudio }

            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("wav")
            defer { try? FileManager.default.removeItem(at: file) }
            guard audio.save(filename: file.path) == 1 else { throw SynthesisError.invalidAudio }
            return try Data(contentsOf: file)
        }

        func releaseCachedVoice() {
            idleReleaseTask?.cancel()
            idleReleaseTask = nil
            tts = nil
        }

        private func scheduleIdleRelease() {
            idleReleaseTask = Task { [weak self] in
                await self?.releaseAfterIdle()
            }
        }

        private func releaseAfterIdle() async {
            do {
                try await Task.sleep(for: .seconds(30))
                try Task.checkCancellation()
            } catch {
                return
            }
            releaseCachedVoice()
        }

        private func loadVoice() throws -> SherpaOnnxOfflineTtsWrapper {
            if let tts { return tts }
            guard let folder = Bundle.main.url(forResource: "OfflineVoice", withExtension: nil) else {
                throw SynthesisError.missingVoicePack
            }
            let lexicons = ["lexicon-us-en.txt", "lexicon-zh.txt"]
            let rules = ["number-zh.fst", "phone-zh.fst", "date-zh.fst"]
            func path(_ name: String) -> String { folder.appendingPathComponent(name).path }
            let files = ["model.int8.onnx", "voices.bin", "tokens.txt"] + lexicons + rules
            guard files.allSatisfy({ FileManager.default.isReadableFile(atPath: path($0)) }) else {
                throw SynthesisError.missingVoicePack
            }

            let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
                model: path("model.int8.onnx"),
                voices: path("voices.bin"),
                tokens: path("tokens.txt"),
                lexicon: lexicons.map(path).joined(separator: ",")
            )
            let model = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: 2)
            var config = sherpaOnnxOfflineTtsConfig(
                model: model,
                ruleFsts: rules.map(path).joined(separator: ",")
            )
            let voice = SherpaOnnxOfflineTtsWrapper(config: &config)
            guard voice.tts != nil, voice.numSpeakers == 1 else { throw SynthesisError.unavailable }
            tts = voice
            return voice
        }
    }
}
