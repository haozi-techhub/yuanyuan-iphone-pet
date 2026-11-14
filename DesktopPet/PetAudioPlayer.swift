@preconcurrency import AVFoundation
import Foundation

@MainActor
final class PetAudioPlayer: NSObject, AVAudioPlayerDelegate {
    enum Cue {
        case expression(PetExpression)
        case march

        var resourceName: String {
            switch self {
            case .march: "march"
            case .expression(let expression):
                switch expression {
                case .idle: "idle"
                case .happy: "happy"
                case .angry: "angry"
                case .proud: "proud"
                case .sad: "sad"
                case .crying: "crying"
                case .surprised: "surprised"
                case .curious: "curious"
                case .celebrate: "celebrate"
                case .delighted: "delighted"
                case .cool: "cool"
                case .affectionate: "affectionate"
                case .sleepy: "sleepy"
                case .dizzy: "dizzy"
                case .musical: "musical"
                case .greeting: "greeting"
                case .shy: "shy"
                case .laughing: "laughing"
                case .winking: "winking"
                case .listening: "listening"
                case .thinking: "thinking"
                case .confused: "confused"
                case .peeking: "peeking"
                case .yawning: "yawning"
                case .kiss: "kiss"
                case .hungry: "hungry"
                case .munching: "munching"
                case .bubbles: "bubbles"
                case .freezing: "freezing"
                case .dancing: "dancing"
                case .charging: "charging"
                case .charged: "charged"
                case .handHeart: "handHeart"
                case .thumbsUp: "thumbsUp"
                case .maracas: "maracas"
                }
            }
        }

        var volume: Float {
            switch self {
            case .march: 0.76
            case .expression(.idle), .expression(.sleepy), .expression(.yawning), .expression(.shy): 0.31
            case .expression: 0.46
            }
        }
    }

    private let audio: SoundSense
    private var player: AVAudioPlayer?
    private var onFinish: (() -> Void)?

    var currentTime: TimeInterval? { player?.currentTime }

    init(audio: SoundSense) {
        self.audio = audio
        super.init()
        audio.onEffectInterrupted = { [weak self] in self?.finish() }
    }

    func play(_ cue: Cue, onFinish: @escaping () -> Void) -> TimeInterval? {
        guard player == nil,
              let url = Bundle.main.url(forResource: cue.resourceName, withExtension: "wav", subdirectory: "PetAudio"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        do { try audio.prepareEffectPlayback() } catch { return nil }
        player.volume = cue.volume
        player.delegate = self
        guard player.play() else {
            audio.finishEffect()
            return nil
        }
        self.player = player
        self.onFinish = onFinish
        return player.duration
    }

    func stop() {
        guard let player else { return }
        player.delegate = nil
        player.stop()
        self.player = nil
        onFinish = nil
        audio.finishEffect()
    }

    private func finish() {
        let callback = onFinish
        stop()
        callback?()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        handleCompletion(ObjectIdentifier(player))
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        handleCompletion(ObjectIdentifier(player))
    }

    private nonisolated func handleCompletion(_ id: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, let player = self.player, ObjectIdentifier(player) == id else { return }
            self.finish()
        }
    }
}
