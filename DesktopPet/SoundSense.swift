@preconcurrency import AVFoundation
import Foundation
import Observation
import os
@preconcurrency import Speech

@MainActor
@Observable
final class SoundSense {
    enum Event {
        case clap, doubleClap, blow, music(Bool)
    }

    private(set) var microphoneDenied = false
    private(set) var statusMessage: String?
    var isPlayingEffect: Bool { effectActive }
    @ObservationIgnored var onEvent: ((Event) -> Void)?
    @ObservationIgnored var onVoiceInterrupted: (() -> Void)?
    @ObservationIgnored var onEffectInterrupted: (() -> Void)?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var interruptionTask: Task<Void, Never>?
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var voiceActive = false
    @ObservationIgnored private var effectActive = false
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var sessionActive = false
    @ObservationIgnored private var captureID = UUID()
    @ObservationIgnored private var detector = Detector()
    @ObservationIgnored private var clapTask: Task<Void, Never>?

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        refreshPermission()
        if enabled && AVAudioApplication.shared.recordPermission == .undetermined {
            requestAmbientPermission()
        }
        updateAmbientCapture()
    }

    func requestAmbientPermission() {
        refreshPermission()
        guard AVAudioApplication.shared.recordPermission == .undetermined, permissionTask == nil else {
            return
        }
        permissionTask = Task { [weak self] in
            _ = await AVAudioApplication.requestRecordPermission()
            guard let self else { return }
            self.permissionTask = nil
            self.refreshPermission()
            self.updateAmbientCapture()
        }
    }

    func requestVoicePermission() async -> Bool {
        if let permissionTask {
            await permissionTask.value
        } else if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        refreshPermission()
        return AVAudioApplication.shared.recordPermission == .granted
    }

    func startVoiceCapture(_ request: SFSpeechAudioBufferRecognitionRequest,
                           onLevel: (@Sendable (Double) -> Void)? = nil) throws {
        try startVoiceCapture { _ in
            Self.recognitionTap(onLevel: onLevel) { request.append($0) }
        }
    }

    func startVoiceCapture(packets: AsyncStream<Data>.Continuation,
                           onLevel: (@Sendable (Double) -> Void)?) throws {
        try startVoiceCapture { format in
            guard let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: Double(DoubaoVoiceClient.sampleRate),
                                          channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: format, to: pcm) else {
                throw AudioError.unavailable
            }
            return Self.recognitionTap(onLevel: onLevel, consume: Self.pcmBufferConsumer(converter, packets: packets))
        }
    }

    private func startVoiceCapture(makeTap: (AVAudioFormat) throws -> AVAudioNodeTapBlock) throws {
        guard !effectActive else { throw AudioError.unavailable }
        voiceActive = true
        resetDetector()
        stopInput()
        try startInput(makeTap: makeTap)
    }

    func stopVoiceCapture() {
        stopInput()
        deactivateSession()
    }

    func prepareVoicePlayback() throws {
        guard !interrupted, !effectActive else { throw AudioError.unavailable }
        voiceActive = true
        stopVoiceCapture()
        try activatePlaybackSession()
    }

    func prepareEffectPlayback() throws {
        guard !interrupted, !voiceActive, !effectActive else { throw AudioError.unavailable }
        effectActive = true
        stopInput()
        resetDetector()
        deactivateSession()
        do {
            try activatePlaybackSession()
        } catch {
            finishEffect()
            throw error
        }
    }

    func finishEffect() {
        guard effectActive else { return }
        deactivateSession()
        effectActive = false
        updateAmbientCapture()
    }

    private func activatePlaybackSession() throws {
        observeInterruptions()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true, options: [])
        sessionActive = true
    }

    func finishVoice() {
        guard voiceActive else { return }
        stopVoiceCapture()
        voiceActive = false
        updateAmbientCapture()
    }

    private func refreshPermission() {
        microphoneDenied = AVAudioApplication.shared.recordPermission == .denied
        if microphoneDenied {
            statusMessage = "请在系统设置中允许桌宠使用麦克风。"
        } else if statusMessage == "请在系统设置中允许桌宠使用麦克风。" {
            statusMessage = nil
        }
    }

    private func updateAmbientCapture() {
        guard !voiceActive, !effectActive else { return }
        guard enabled, !interrupted, AVAudioApplication.shared.recordPermission == .granted else {
            stopInput()
            deactivateSession()
            resetDetector()
            return
        }
        guard engine == nil else { return }

        do {
            let id = UUID()
            captureID = id
            try startInput(tap: Self.ambientTap { [weak self] sample in
                Task { @MainActor [weak self] in
                    guard let self, self.captureID == id, self.enabled, !self.voiceActive else { return }
                    self.handle(sample)
                }
            })
            statusMessage = nil
        } catch {
            stopInput()
            deactivateSession()
            statusMessage = "无法使用麦克风，请检查音频设备后重试。"
        }
    }

    private func startInput(tap: @escaping AVAudioNodeTapBlock) throws {
        try startInput { _ in tap }
    }

    private func startInput(makeTap: (AVAudioFormat) throws -> AVAudioNodeTapBlock) throws {
        guard !interrupted else { throw AudioError.unavailable }
        observeInterruptions()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        if !sessionActive {
            try session.setActive(true, options: [])
            sessionActive = true
        }

        let engine = AVAudioEngine()
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.unavailable }
        node.installTap(onBus: 0, bufferSize: 512, format: format, block: try makeTap(format))
        self.engine = engine
        engine.prepare()
        try engine.start()
    }

    private func stopInput() {
        guard let engine else { return }
        captureID = UUID()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    private func deactivateSession() {
        guard sessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
    }

    private func observeInterruptions() {
        guard interruptionTask == nil else { return }
        let interruptions = NotificationCenter.default.notifications(
            named: AVAudioSession.interruptionNotification
        ).compactMap { notification in
            notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        }
        interruptionTask = Task { [weak self] in
            for await raw in interruptions {
                guard let self else { return }
                self.interrupted = raw == AVAudioSession.InterruptionType.began.rawValue
                if self.interrupted {
                    self.sessionActive = false
                    if self.voiceActive { self.onVoiceInterrupted?() }
                    if self.effectActive { self.onEffectInterrupted?() }
                }
                self.updateAmbientCapture()
            }
        }
    }

    private enum AudioError: Error { case unavailable }

    private nonisolated static func recognitionTap(
        onLevel: (@Sendable (Double) -> Void)?,
        consume: @escaping (AVAudioPCMBuffer) -> Void
    ) -> AVAudioNodeTapBlock {
        var frames = 0
        var peakPower = 0.0
        return { buffer, _ in
            consume(buffer)
            guard let onLevel, let channel = buffer.floatChannelData?.pointee else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var power = 0.0
            for index in 0..<count {
                let value = channel[index * buffer.stride]
                power += Double(value * value)
            }
            peakPower = max(peakPower, power / Double(count))
            frames += count
            if Double(frames) >= buffer.format.sampleRate * 0.05 {
                onLevel(10 * log10(max(peakPower, 0.00000001)))
                frames = 0
                peakPower = 0
            }
        }
    }

    private nonisolated static func pcmBufferConsumer(
        _ converter: AVAudioConverter, packets: AsyncStream<Data>.Continuation
    ) -> (AVAudioPCMBuffer) -> Void {
        return { buffer in
            let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
            let provided = OSAllocatedUnfairLock(initialState: false)
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                let alreadyProvided = provided.withLock { value in
                    let previous = value
                    value = true
                    return previous
                }
                if alreadyProvided {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, output.frameLength > 0, let samples = output.int16ChannelData?.pointee else { return }
            packets.yield(Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size))
        }
    }

    private nonisolated static func ambientTap(
        _ receive: @escaping @Sendable (Sample) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let channel = buffer.floatChannelData?.pointee else { return }
            let count = Int(buffer.frameLength)
            guard count > 1 else { return }
            var sum = 0.0
            var crossings = 0
            var last = channel[0]
            for index in 0..<count {
                let value = channel[index * buffer.stride]
                sum += Double(value * value)
                if (value < 0) != (last < 0) { crossings += 1 }
                last = value
            }
            receive(Sample(
                level: 10 * log10(max(sum / Double(count), 0.00000001)),
                zeroCrossingRate: Double(crossings) / Double(count - 1),
                time: ProcessInfo.processInfo.systemUptime
            ))
        }
    }

    private func resetDetector() {
        clapTask?.cancel()
        clapTask = nil
        if detector.music { onEvent?(.music(false)) }
        detector = Detector()
    }

    private func handle(_ sample: Sample) {
        let result = detector.add(sample)
        if let music = result.music {
            onEvent?(.music(music))
        }
        if result.blow {
            onEvent?(.blow)
        }
        if result.clap, !detector.music {
            if let clapTask {
                clapTask.cancel()
                self.clapTask = nil
                onEvent?(.doubleClap)
            } else {
                clapTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(370)) } catch { return }
                    self?.clapTask = nil
                    self?.onEvent?(.clap)
                }
            }
        }
    }

    private struct Sample: Sendable {
        let level: Double
        let zeroCrossingRate: Double
        let time: TimeInterval
    }

    private struct Detector {
        private var floor = -56.0
        private var recentLevels: [(TimeInterval, Double)] = []
        private var transient: (time: TimeInterval, level: Double)?
        private var lastClap: TimeInterval = -.infinity
        private var lastBeat: TimeInterval = -.infinity
        private var lastStableBeat: TimeInterval = -.infinity
        private var beats: [TimeInterval] = []
        private var blowStarted: TimeInterval?
        private var blew = false
        private(set) var music = false

        mutating func add(_ sample: Sample) -> (clap: Bool, blow: Bool, music: Bool?) {
            let time = sample.time
            recentLevels.removeAll { time - $0.0 > 0.05 }
            let previousLevel = recentLevels.last?.1 ?? sample.level
            let recentLow = recentLevels.lazy.map(\.1).min() ?? sample.level
            recentLevels.append((time, sample.level))
            var clap = false
            var blow = false
            let wasMusic = music

            if let spike = transient {
                if time - spike.time > 0.15 {
                    transient = nil
                } else if sample.level < spike.level + 8 {
                    clap = true
                    lastClap = time
                    transient = nil
                }
            } else if time - lastClap > 0.11, sample.level > -29, sample.level - recentLow >= 20 {
                transient = (time, recentLow)
            }

            if sample.level > max(floor + 12, -40), sample.zeroCrossingRate < 0.12 {
                if blowStarted == nil { blowStarted = time }
                if !blew, let start = blowStarted, time - start >= 0.6, !music {
                    blow = true
                    blew = true
                }
            } else {
                blowStarted = nil
                blew = false
            }

            if sample.level - previousLevel >= 6, sample.level > max(floor + 10, -46),
               time - lastBeat > 0.29 {
                lastBeat = time
                beats.append(time)
                beats.removeAll { time - $0 > 4 }
                if beats.count >= 4 {
                    let intervals = zip(beats.dropFirst(), beats).map { $0.0 - $0.1 }
                    let average = intervals.reduce(0, +) / Double(intervals.count)
                    let variance = intervals.map { pow($0 - average, 2) }.reduce(0, +)
                        / Double(intervals.count)
                    if (60.0 / 180.0...1).contains(average), sqrt(variance) / average < 0.25 {
                        music = true
                        lastStableBeat = time
                    }
                }
            }
            if time - lastStableBeat > 2.2 {
                music = false
            }
            if sample.level < floor + 8 {
                floor = min(-25, max(-75, floor + (sample.level - floor) * 0.035))
            }
            return (clap, blow, wasMusic == music ? nil : music)
        }
    }
}
