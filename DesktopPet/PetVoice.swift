@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech

@MainActor
@Observable
final class PetVoice: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let defaultPetName = "圆圆"

    enum Phase: Equatable {
        case idle, authorizing, listening, thinking, speaking
    }

    enum Command: Equatable {
        case none
        case setMode(String)
        case nightLightTimer(Int)
        case countdown(Int)
    }

    private enum WakeCapture {
        case waiting, addressed, subsequentPhrase
    }

    private(set) var phase: Phase = .idle
    private(set) var isCapturingSpeech = false
    private(set) var caption: String?
    private(set) var mouthOpen = 0.0
    private(set) var hasAPIKey: Bool
    private(set) var isPreviewing = false
    private(set) var voiceOutputNotice: String?
    private(set) var speechPermissionDenied = false
    private(set) var isWaitingForWake = false
    private(set) var wakeNotice: String?
    private(set) var lastTranscript: String?

    var canRecord: Bool { phase == .idle && !isPreviewing }

    @ObservationIgnored var onReply: ((PetExpression, Command) -> Void)?
    @ObservationIgnored var batteryStatusReply: (() -> String?)?
    @ObservationIgnored var onMarchRequested: (() -> Void)?
    @ObservationIgnored private let audio: SoundSense
    @ObservationIgnored private let client = DeepSeekClient()
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var localPlaybackText: String?
    @ObservationIgnored private var outputTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReply: (expression: PetExpression, command: Command)?
    @ObservationIgnored private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var speechTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var speechLimitTask: Task<Void, Never>?
    @ObservationIgnored private var mouthTask: Task<Void, Never>?
    @ObservationIgnored private var captionTask: Task<Void, Never>?
    @ObservationIgnored private var utteranceID: ObjectIdentifier?
    @ObservationIgnored private var turnID = UUID()
    @ObservationIgnored private var isHeld = false
    @ObservationIgnored private var pushToTalk = true
    @ObservationIgnored private var latestText = ""
    @ObservationIgnored private var recognitionFinished = false
    @ObservationIgnored private var history: [DeepSeekClient.Message] = []
    @ObservationIgnored private var persona = Persona(model: "", name: "", personality: "")
    @ObservationIgnored private var wakePersona: Persona?
    @ObservationIgnored private var wakeCapture: WakeCapture?
    @ObservationIgnored private var wakeStartTask: Task<Void, Never>?
    @ObservationIgnored private var wakeSilenceTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTranscript: String?

    init(audio: SoundSense) {
        self.audio = audio
        hasAPIKey = (try? KeychainStore.readAPIKey()) != nil
        super.init()
        synthesizer.usesApplicationAudioSession = true
        synthesizer.delegate = self
        audio.onVoiceInterrupted = { [weak self] in self?.cancel() }
        refreshPermissions()
    }

    func refreshPermissions() {
        let status = SFSpeechRecognizer.authorizationStatus()
        speechPermissionDenied = status == .denied || status == .restricted
    }

    func saveAPIKey(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            try removeAPIKey()
        } else {
            try KeychainStore.saveAPIKey(key)
            hasAPIKey = true
            history.removeAll()
        }
    }

    func removeAPIKey() throws {
        try KeychainStore.removeAPIKey()
        hasAPIKey = false
        history.removeAll()
    }

    func previewVoice() {
        guard canRecord else { return }
        stopWaitingForWake()
        turnID = UUID()
        isPreviewing = true
        playVoice("你好呀，我是\(Self.defaultPetName)。今天也陪着你。")
    }

    func stopPreview() {
        if isPreviewing { cancel() }
    }

    func begin(model: String, name: String, personality: String, pushToTalk: Bool = true) {
        guard canRecord else { return }
        stopWaitingForWake()
        usePersona(Persona(model: model, name: name, personality: personality))
        let id = UUID()
        turnID = id
        self.pushToTalk = pushToTalk
        isHeld = true
        captionTask?.cancel()
        phase = .authorizing
        caption = "正在准备麦克风…"
        latestText = ""
        recognitionFinished = false
        turnTask = Task { [weak self] in
            await self?.authorizeAndListen(id: id)
        }
    }

    func configureWake(enabled: Bool, model: String, name: String, personality: String) {
        let next = enabled ? Persona(model: model, name: name, personality: personality) : nil
        guard next != wakePersona else { return }
        wakePersona = next
        wakeNotice = nil
        if wakeCapture == .waiting {
            stopWaitingForWake()
        } else if !enabled, wakeCapture != nil, phase == .listening {
            cancel()
        }
        if enabled {
            scheduleWake()
        } else {
            wakeStartTask?.cancel()
            wakeStartTask = nil
        }
    }

    func pauseWakeForExpressionAudio() {
        guard phase == .idle, !isPreviewing, wakePersona != nil else { return }
        stopWaitingForWake()
        scheduleWake()
    }

    private func usePersona(_ newPersona: Persona) {
        guard persona != newPersona else { return }
        history.removeAll()
        persona = newPersona
    }

    func end() {
        isHeld = false
        guard phase == .listening else { return }
        if wakeCapture != nil, latestText.isEmpty {
            endWakeWithoutSpeech()
            return
        }
        phase = .thinking
        caption = "让我想想…"
        speechLimitTask?.cancel()
        speechLimitTask = nil
        wakeSilenceTask?.cancel()
        wakeSilenceTask = nil
        finishCapture()

        let id = turnID
        if recognitionFinished {
            submitTranscript(id: id)
        } else {
            speechLimitTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
                self?.submitTranscript(id: id)
            }
        }
    }

    func cancel() {
        turnID = UUID()
        isHeld = false
        turnTask?.cancel()
        turnTask = nil
        wakeStartTask?.cancel()
        wakeStartTask = nil
        speechLimitTask?.cancel()
        speechLimitTask = nil
        wakeSilenceTask?.cancel()
        wakeSilenceTask = nil
        isWaitingForWake = false
        wakeCapture = nil
        wakeTranscript = nil
        clearRecognition()
        utteranceID = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finishSpeaking()
        captionTask?.cancel()
        caption = nil
    }

    private func authorizeAndListen(id: UUID) async {
        let microphoneAllowed = await audio.requestVoicePermission()
        guard isCurrent(id) else { return }
        guard microphoneAllowed else {
            endWithStatus("请在系统设置中允许圆圆使用麦克风。")
            return
        }

        let speechStatus = await Self.requestSpeechAuthorization()
        guard isCurrent(id) else { return }
        refreshPermissions()
        guard speechStatus == .authorized else {
            endWithStatus("请在系统设置中允许圆圆使用语音识别。")
            return
        }
        guard isHeld else {
            endWithStatus(pushToTalk ? "已准备好，再按住就可以说话。" : "已准备好，再上滑就可以说话。")
            return
        }
        guard supportsOfflineRecognition else {
            endWithStatus("当前设备的离线普通话识别不可用。")
            return
        }

        guard startRecognition(id: id) else {
            endWithStatus("无法启动麦克风，请稍后再试。")
            return
        }
        isCapturingSpeech = true
        phase = .listening
        caption = pushToTalk ? "松开发送" : "再次上滑发送"
        scheduleListeningLimit(id: id)
    }

    private var supportsOfflineRecognition: Bool {
        recognizer?.supportsOnDeviceRecognition == true && recognizer?.isAvailable == true
    }

    private func startRecognition(id: UUID) -> Bool {
        guard let recognizer else { return false }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.contextualStrings = [persona.name, Self.defaultPetName, "嗨，\(persona.name)", "唱首歌", "圆圆进行曲",
                                     "跳个舞", "打招呼", "比个心", "点个赞", "吹泡泡", "摇沙锤", "夜灯", "饱腹度"]
        speechRequest = request
        speechTask = recognizer.recognitionTask(with: request, resultHandler: Self.speechHandler { [weak self] update in
            Task { @MainActor [weak self] in
                self?.receive(update, id: id)
            }
        })

        do {
            try audio.startVoiceCapture(request)
            return true
        } catch {
            clearRecognition()
            audio.finishVoice()
            return false
        }
    }

    private func scheduleListeningLimit(id: UUID) {
        speechLimitTask?.cancel()
        speechLimitTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.isCurrent(id) else { return }
            self.end()
        }
    }

    private func scheduleWake(after delay: Duration = .milliseconds(700)) {
        guard wakePersona != nil, canRecord, wakeCapture == nil, wakeStartTask == nil else { return }
        wakeStartTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            self.wakeStartTask = nil
            guard self.canRecord, let persona = self.wakePersona, self.wakeCapture == nil else { return }
            if self.audio.isPlayingEffect {
                self.scheduleWake(after: .seconds(2))
                return
            }
            await self.startWake(persona)
        }
    }

    private func startWake(_ configuration: Persona) async {
        let id = UUID()
        turnID = id
        wakeCapture = .waiting
        let microphoneAllowed = await audio.requestVoicePermission()
        guard isCurrent(id), wakePersona == configuration else { return }
        guard microphoneAllowed else {
            wakeCapture = nil
            wakeNotice = "允许麦克风权限后才可以语音唤醒。"
            return
        }
        let speechStatus = await Self.requestSpeechAuthorization()
        guard isCurrent(id), wakePersona == configuration else { return }
        refreshPermissions()
        guard speechStatus == .authorized, supportsOfflineRecognition else {
            wakeCapture = nil
            wakeNotice = speechStatus == .authorized
                ? "当前设备的离线普通话识别不可用。"
                : "允许语音识别权限后才可以语音唤醒。"
            return
        }

        usePersona(configuration)
        guard !audio.isPlayingEffect, startRecognition(id: id) else {
            wakeCapture = nil
            scheduleWake(after: .seconds(2))
            return
        }
        wakeNotice = nil
        isWaitingForWake = true
        speechLimitTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self, self.isCurrent(id), self.wakeCapture == .waiting else { return }
            self.stopWaitingForWake()
            self.scheduleWake()
        }
    }

    private func stopWaitingForWake() {
        wakeStartTask?.cancel()
        wakeStartTask = nil
        guard wakeCapture == .waiting else { return }
        turnID = UUID()
        speechLimitTask?.cancel()
        speechLimitTask = nil
        wakeSilenceTask?.cancel()
        wakeSilenceTask = nil
        wakeTranscript = nil
        isWaitingForWake = false
        wakeCapture = nil
        clearRecognition()
        audio.finishVoice()
    }

    private func receiveWake(_ update: SpeechUpdate, id: UUID, capture: WakeCapture) {
        switch capture {
        case .waiting:
            let phrase = update.text.flatMap { Self.addressedPhrase($0, name: persona.name) }
            if let phrase, !phrase.isEmpty || update.finished {
                acceptWake(phrase, id: id)
                if update.finished { completeWakePhrase(id: id) }
            } else if update.finished {
                stopWaitingForWake()
                scheduleWake()
            } else if let text = update.text, text != wakeTranscript {
                scheduleWakePause(after: text, addressed: phrase != nil, id: id)
            }
        case .addressed:
            if let text = update.text {
                updateWakeTranscript(Self.addressedPhrase(text, name: persona.name) ?? "", id: id)
            }
            if update.finished { completeWakePhrase(id: id) }
        case .subsequentPhrase:
            if let text = update.text { updateWakeTranscript(text, id: id) }
            if update.finished { completeWakePhrase(id: id) }
        }
    }

    private func scheduleWakePause(after text: String, addressed: Bool, id: UUID) {
        wakeTranscript = text
        wakeSilenceTask?.cancel()
        wakeSilenceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(addressed ? 650 : 1_400)) } catch { return }
            guard let self, self.isCurrent(id), self.wakeCapture == .waiting else { return }
            self.wakeSilenceTask = nil
            if addressed {
                self.acceptWake("", id: id)
            } else {
                self.stopWaitingForWake()
                self.scheduleWake()
            }
        }
    }

    private func acceptWake(_ phrase: String, id: UUID) {
        wakeCapture = .addressed
        wakeTranscript = nil
        latestText = ""
        recognitionFinished = false
        isWaitingForWake = false
        isCapturingSpeech = true
        captionTask?.cancel()
        phase = .listening
        scheduleListeningLimit(id: id)
        updateWakeTranscript(phrase, id: id)
    }

    private func updateWakeTranscript(_ phrase: String, id: UUID) {
        guard wakeTranscript != phrase else { return }
        wakeTranscript = phrase
        latestText = phrase
        caption = phrase.isEmpty ? "我在听…" : phrase
        wakeSilenceTask?.cancel()
        wakeSilenceTask = nil
        guard !phrase.isEmpty else { return }
        wakeSilenceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1_400)) } catch { return }
            guard let self, self.isCurrent(id), self.phase == .listening else { return }
            self.end()
        }
    }

    private func completeWakePhrase(id: UUID) {
        if !latestText.isEmpty {
            recognitionFinished = true
            end()
        } else if wakeCapture == .addressed {
            clearRecognition()
            wakeCapture = .subsequentPhrase
            let nextID = UUID()
            turnID = nextID
            if startRecognition(id: nextID) {
                isCapturingSpeech = true
                scheduleListeningLimit(id: nextID)
            } else {
                endWakeWithoutSpeech()
            }
        } else if isCurrent(id) {
            endWakeWithoutSpeech()
        }
    }

    private func endWakeWithoutSpeech() {
        turnID = UUID()
        wakeCapture = nil
        wakeTranscript = nil
        clearRecognition()
        finishSpeaking()
        caption = nil
    }

    private func endWithStatus(_ status: String) {
        isHeld = false
        phase = .idle
        caption = status
        expireCaption()
        scheduleWake()
    }

    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private struct SpeechUpdate: Sendable {
        let text: String?
        let alternatives: [String]
        let finished: Bool
    }

    private nonisolated static func speechHandler(
        _ receive: @escaping @Sendable (SpeechUpdate) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            receive(SpeechUpdate(
                text: result?.bestTranscription.formattedString,
                alternatives: result.map { $0.transcriptions.dropFirst().prefix(2).map(\.formattedString) } ?? [],
                finished: result?.isFinal == true || error != nil
            ))
        }
    }

    private func receive(_ update: SpeechUpdate, id: UUID) {
        guard isCurrent(id), speechTask != nil else { return }
        if let wakeCapture, phase != .thinking {
            receiveWake(update, id: id, capture: wakeCapture)
            return
        }
        if let text = update.text, !text.isEmpty {
            if wakeCapture == .addressed {
                latestText = Self.addressedPhrase(text, name: persona.name) ?? ""
            } else {
                latestText = text
            }
            if wakeCapture != .addressed, update.finished {
                latestText = Self.correctMarchTitle(in: latestText, using: update.alternatives, name: persona.name)
            }
            if phase == .listening { caption = latestText }
        }
        if update.finished {
            recognitionFinished = true
            if phase == .listening {
                finishCapture()
                if latestText.isEmpty { caption = pushToTalk ? "松开就可以发送。" : "再次上滑发送。" }
            } else if phase == .thinking {
                submitTranscript(id: id)
            }
        }
    }

    private func finishCapture() {
        isCapturingSpeech = false
        guard let request = speechRequest else { return }
        audio.stopVoiceCapture()
        request.endAudio()
        speechRequest = nil
    }

    private func clearRecognition() {
        finishCapture()
        speechTask?.cancel()
        speechTask = nil
    }

    private func submitTranscript(id: UUID) {
        guard turnID == id, phase == .thinking, speechTask != nil else { return }
        speechLimitTask?.cancel()
        speechLimitTask = nil
        clearRecognition()
        let text = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        wakeCapture = nil
        wakeTranscript = nil
        guard !text.isEmpty else {
            speak("我没听清，再说一次吧。", expression: .confused)
            return
        }
        lastTranscript = text
        turnTask = Task { [weak self] in
            await self?.respond(to: text, id: id)
        }
    }

    private func respond(to text: String, id: UUID) async {
        guard isCurrent(id) else { return }
        let phrase = Self.addressedPhrase(text, name: persona.name) ?? text
        if phrase.isEmpty {
            speak("我在呢。", expression: .greeting)
            return
        }
        if Self.isMarchRequest(phrase) {
            caption = nil
            finishSpeaking()
            onMarchRequested?()
            return
        }
        if Self.isBatteryQuestion(phrase) {
            speak(batteryStatusReply?() ?? "切到电量宠物模式，我就能告诉你。", expression: .idle)
            return
        }
        if let localReply = Self.localReply(to: phrase) {
            speak(localReply.text, expression: localReply.expression, command: localReply.command)
            return
        }

        guard let key = try? KeychainStore.readAPIKey(), !key.isEmpty else {
            speak("可以叫我唱歌、跳舞，或者比个心。", expression: .curious)
            return
        }

        let user = DeepSeekClient.Message(role: "user", content: phrase)
        let messages = [DeepSeekClient.Message(role: "system", content: persona.prompt)] + history + [user]
        do {
            let response = try await client.reply(apiKey: key, model: persona.model, messages: messages)
            guard isCurrent(id) else { return }
            let command = Self.validate(response.command, spoken: phrase)
            if let type = response.command?.type, type != "none", command == .none {
                speak("我没确认你想让我做什么，再说一次吧。", expression: .confused)
                return
            }
            let reply = String(response.reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            let emotion = response.emotion.flatMap { Emotion(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let expression = command == .none ? (emotion ?? .neutral).expression : .happy
            history.append(contentsOf: [user, .init(role: "assistant", content: reply)])
            history = Array(history.suffix(16))
            speak(reply, expression: expression, command: command)
        } catch {
            guard isCurrent(id) else { return }
            switch error {
            case DeepSeekClient.RequestError.httpStatus(401):
                speak("DeepSeek 密钥无效，请检查语音设置。", expression: .confused)
            case DeepSeekClient.RequestError.httpStatus(402):
                speak("DeepSeek 余额不足，请检查账户。", expression: .confused)
            case DeepSeekClient.RequestError.httpStatus(429):
                speak("DeepSeek 现在有点忙，等会儿再聊吧。", expression: .confused)
            case DeepSeekClient.RequestError.invalidResponse:
                speak("我没听清，再说一次吧。", expression: .confused)
            case is URLError:
                speak("暂时连不上网络，我还能跳舞和开夜灯。", expression: .confused)
            default:
                speak("DeepSeek 暂时无法回答，请检查语音设置。", expression: .confused)
            }
        }
    }

    private func speak(_ text: String, expression: PetExpression, command: Command = .none) {
        caption = text
        phase = .speaking
        pendingReply = (expression, command)
        playVoice(text)
    }

    private func playVoice(_ text: String) {
        voiceOutputNotice = nil
        let id = turnID
        outputTask = Task { [weak self] in
            let data = try? await LocalTTSClient.synthesize(text: text)
            guard let self, self.isCurrent(id) else { return }
            self.outputTask = nil
            if data == nil { self.noteVoicePackFallback() }
            self.startPlayback(text, audioData: data)
        }
    }

    private func startPlayback(_ text: String, audioData: Data? = nil) {
        do {
            try audio.prepareVoicePlayback()
        } catch {
            voiceOutputNotice = "暂时无法播放语音。"
            presentReply()
            finishSpeaking()
            return
        }

        if let audioData {
            if startLocalPlayback(audioData) {
                localPlaybackText = text
                schedulePlaybackLimit()
                presentReply()
                return
            }
            noteVoicePackFallback()
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.defaultPetVoice()
        utterance.pitchMultiplier = 1.12
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.90
        utteranceID = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
        schedulePlaybackLimit()
        presentReply()
    }

    private func presentReply() {
        guard let reply = pendingReply else { return }
        pendingReply = nil
        onReply?(reply.expression, reply.command)
    }

    private func noteVoicePackFallback() {
        voiceOutputNotice = "内置语音包暂不可用，正在使用 iPhone 系统音色。"
    }

    private func startLocalPlayback(_ data: Data) -> Bool {
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        player.delegate = self
        player.isMeteringEnabled = true
        guard player.play() else { return false }
        self.player = player
        let id = turnID
        mouthTask = Task { [weak self] in
            while let self, self.isCurrent(id), let player = self.player, player.isPlaying {
                player.updateMeters()
                let level = Double(player.averagePower(forChannel: 0))
                let opening = min(1, max(0, (level + 45) / 32))
                self.mouthOpen = self.mouthOpen * 0.36 + opening * 0.64
                do { try await Task.sleep(for: .milliseconds(45)) } catch { return }
            }
        }
        return true
    }

    private func schedulePlaybackLimit() {
        let id = turnID
        speechLimitTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.isCurrent(id) else { return }
            if self.synthesizer.isSpeaking { self.synthesizer.stopSpeaking(at: .immediate) }
            self.finishSpeaking()
        }
    }

    private static func defaultPetVoice() -> AVSpeechSynthesisVoice? {
        let language = "zh-CN"
        let voice = AVSpeechSynthesisVoice.speechVoices()
            .filter {
                $0.language == language && $0.gender == .female
                    && !$0.voiceTraits.contains(.isPersonalVoice)
                    && !$0.voiceTraits.contains(.isNoveltyVoice)
            }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        return voice ?? AVSpeechSynthesisVoice(language: language)
    }

    private func finishSpeaking() {
        outputTask?.cancel()
        outputTask = nil
        pendingReply = nil
        utteranceID = nil
        stopLocalPlayback()
        speechLimitTask?.cancel()
        speechLimitTask = nil
        mouthTask?.cancel()
        mouthTask = nil
        mouthOpen = 0
        audio.finishVoice()
        isPreviewing = false
        phase = .idle
        expireCaption()
        scheduleWake()
    }

    private func stopLocalPlayback() {
        player?.delegate = nil
        player?.stop()
        player = nil
        localPlaybackText = nil
    }

    private func expireCaption() {
        captionTask?.cancel()
        captionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard let self, self.phase == .idle else { return }
            self.caption = nil
        }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        turnID == id && !Task.isCancelled
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.utteranceID == id else { return }
            self.mouthOpen = 0.78
            self.mouthTask?.cancel()
            self.mouthTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
                self?.mouthOpen = 0
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        notifySpeechFinished(ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        notifySpeechFinished(ObjectIdentifier(utterance))
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        notifyPlayerFinished(ObjectIdentifier(player), successfully: flag)
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        notifyPlayerFinished(ObjectIdentifier(player), successfully: false)
    }

    private nonisolated func notifyPlayerFinished(_ id: ObjectIdentifier, successfully: Bool) {
        Task { @MainActor [weak self] in
            guard let self, let player = self.player, ObjectIdentifier(player) == id else { return }
            if !successfully, let text = self.localPlaybackText {
                self.stopLocalPlayback()
                self.speechLimitTask?.cancel()
                self.mouthTask?.cancel()
                self.mouthOpen = 0
                self.noteVoicePackFallback()
                self.startPlayback(text)
                return
            }
            self.finishSpeaking()
        }
    }

    private nonisolated func notifySpeechFinished(_ id: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, self.utteranceID == id else { return }
            self.finishSpeaking()
        }
    }

    private struct Persona: Equatable {
        let model: String
        let name: String
        let personality: String

        var prompt: String {
            let petName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let style = personality.trimmingCharacters(in: .whitespacesAndNewlines)
            let emotions = Emotion.allCases.map(\.rawValue).joined(separator: "、")
            return """
            你是桌宠，名字是「\(petName.isEmpty ? PetVoice.defaultPetName : String(petName.prefix(32)))」，性格是「\(style.isEmpty ? "元气" : String(style.prefix(100)))」。
            用可爱的简体中文说一句话，reply 不超过 40 字。只输出一个 json 对象。
            emotion 表示最新一句中用户本人表达的情绪，结合上下文判断。只选以下一个：\(emotions)。
            明确报喜或完成值得庆祝的事选庆祝，普通开心选喜悦。转述别人的情绪、含糊或无情绪时选中性。
            回复要贴合情绪，疲惫或难过时温柔回应，用户生气时平静理解，避免强行逗乐。
            设备的电量和充电状态以系统为准，不猜测。
            只有用户明确要求设备操作时才选指令。setMode 的 value 只能是 normal、companion、battery、nightLight。
            nightLightTimer 的 value 为 15、30、60 分钟之一。countdown 的 value 为 1 到 7200 之间的秒数。
            指令的 value 一律为字符串。其他时候使用 none。
            示例：{"reply":"辛苦啦，陪你歇一会儿。","emotion":"疲惫","command":{"type":"none","value":""}}
            """
        }
    }

    private enum Emotion: String, CaseIterable {
        case neutral = "中性"
        case joy = "喜悦"
        case celebration = "庆祝"
        case sadness = "难过"
        case tiredness = "疲惫"
        case anxiety = "紧张"
        case anger = "生气"
        case surprise = "惊讶"
        case confusion = "困惑"

        var expression: PetExpression {
            switch self {
            case .neutral, .anger: .idle
            case .joy: .happy
            case .celebration: .celebrate
            case .sadness, .tiredness, .anxiety: .affectionate
            case .surprise: .surprised
            case .confusion: .curious
            }
        }
    }

    private struct LocalReply {
        let text: String
        let expression: PetExpression
        var command: Command = .none
    }

    private static func normalizedCommand(_ text: String) -> String {
        simplified(text).lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static func simplified(_ text: String) -> String {
        text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
    }

    private static func singleUtterance(_ text: String) -> String {
        let sentenceEndings = CharacterSet(charactersIn: "。.!！?？")
        return simplified(text).trimmingCharacters(in: .whitespacesAndNewlines.union(sentenceEndings))
            .filter { !$0.isWhitespace }
    }

    private static func addressedPhrase(_ spoken: String, name: String) -> String? {
        let separators = CharacterSet(charactersIn: "，,。；;、：:！!？?").union(.whitespacesAndNewlines)
        let text = simplified(spoken).trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredName = simplified(name).trimmingCharacters(in: .whitespacesAndNewlines)
        let names = configuredName.isEmpty || configuredName == defaultPetName
            ? [defaultPetName, "元元", "园园"] : [configuredName]
        for greeting in ["你好", "嘿", "嗨", ""] where text.hasPrefix(greeting) {
            let address = String(String.UnicodeScalarView(text.dropFirst(greeting.count).unicodeScalars.drop(while: separators.contains)))
            for name in names where address.lowercased().hasPrefix(name.lowercased()) {
                let remainder = address.dropFirst(name.count)
                let phrase = String(String.UnicodeScalarView(remainder.unicodeScalars.drop(while: separators.contains)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if phrase.isEmpty || remainder.unicodeScalars.first.map(separators.contains) == true
                    || isMarchRequest(phrase) || isBatteryQuestion(phrase) || localReply(to: phrase) != nil {
                    return phrase
                }
            }
        }
        return nil
    }

    private static func isMarchRequest(_ spoken: String) -> Bool {
        let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?？")))
        guard let action = requestedAction(from: text) else { return false }
        if action.wholeMatch(of: #/(?:唱(?:一?(?:首|段|下))?歌|唱唱歌|来一?首歌)/#) != nil { return true }
        return action.wholeMatch(of: #/(?:唱|播放|放|来|我(?:想|要)听)(?:一?(?:首|段|下))?[《「]?(?:圆圆|元元|园园|缘缘)?进行曲[》」]?/#) != nil
    }

    private static func correctMarchTitle(in transcript: String, using alternatives: [String], name: String) -> String {
        // The best transcript must already request a song before an alternative can repair its title.
        let phrase = addressedPhrase(transcript, name: name) ?? transcript
        guard let action = requestedAction(from: phrase),
              action.wholeMatch(of: #/(?:唱|播放|放|来|我(?:想|要)听)(?:一?(?:首|段|下))?[《「]?(?:圆圆|元元|园园|缘缘)(?:进行|进形|进程|运行)[曲去续][》」]?/#) != nil,
              !isMarchRequest(phrase) else { return transcript }
        return alternatives.first { candidate in
            isMarchRequest(addressedPhrase(candidate, name: name) ?? candidate)
        } ?? transcript
    }

    private static func isBatteryQuestion(_ spoken: String) -> Bool {
        let text = singleUtterance(spoken)
        return text.wholeMatch(of: #/(?:请问)?(?:你(?:的)?|手机(?:的)?|桌宠(?:的)?|现在|目前)*(?:充满(?:电)?了?吗|电充满了?吗|充满电(?:了)?没有|电量(?:还剩|剩下|是)?多少|还有多少电|还剩多少电|饱腹度多少|(?:正在|在)充电吗)/#) != nil
    }

    private static func localReply(to spoken: String) -> LocalReply? {
        guard let action = requestedAction(from: spoken) else { return nil }
        if action.wholeMatch(of: #/跳(?:一?[个支段曲])?舞(?:给我看)?/#) != nil {
            return LocalReply(text: "看我的，开跳！", expression: .dancing)
        }
        if action.wholeMatch(of: #/吹(?:(?:一|几)?[个串])?泡泡/#) != nil {
            return LocalReply(text: "看，泡泡飞起来啦！", expression: .bubbles)
        }
        switch action {
        case "回窝睡觉", "去睡觉", "睡觉", "睡一会儿":
            return LocalReply(text: "晚安，我先眯一会儿。", expression: .sleepy)
        case "打招呼", "打个招呼", "打声招呼", "挥手", "挥挥手":
            return LocalReply(text: "嗨，我在这儿！", expression: .greeting)
        case "比心", "比个心", "比一个心", "双手比心", "用双手比心":
            return LocalReply(text: "送你一颗心！", expression: .handHeart)
        case "点赞", "点个赞", "点一个赞", "竖大拇指":
            return LocalReply(text: "给你点个赞！", expression: .thumbsUp)
        case "眨眼", "眨眨眼", "眨个眼", "卖个萌":
            return LocalReply(text: "看我这边。", expression: .winking)
        case "笑一个", "笑一笑":
            return LocalReply(text: "嘿嘿！", expression: .laughing)
        case "飞吻", "送个飞吻", "亲一个":
            return LocalReply(text: "啵！", expression: .kiss)
        case "摇沙锤", "摇摇沙锤":
            return LocalReply(text: "听我的节奏！", expression: .maracas)
        case "庆祝", "庆祝一会儿", "放个彩带", "喷个彩带":
            return LocalReply(text: "好耶，庆祝一下！", expression: .celebrate)
        case "耍帅", "耍个帅", "戴墨镜":
            return LocalReply(text: "看我帅不帅？", expression: .cool)
        case "开夜灯", "开启夜灯", "打开夜灯", "开个夜灯", "切换到夜灯模式", "打开夜灯模式":
            return LocalReply(text: "给你留一盏暖暖的小灯。", expression: .happy, command: .setMode("nightLight"))
        case "关夜灯", "关闭夜灯", "切换到陪伴模式", "开启陪伴模式", "打开陪伴模式":
            return LocalReply(text: "我回来陪你啦。", expression: .happy, command: .setMode("companion"))
        case "切换到普通模式", "切到普通模式", "开启普通模式", "打开普通模式":
            return LocalReply(text: "来看看我下一个表情！", expression: .happy, command: .setMode("normal"))
        case "切换到电量宠物模式", "开启电量宠物模式", "打开电量宠物模式":
            return LocalReply(text: "现在可以看我的饱腹度啦。", expression: .happy, command: .setMode("battery"))
        default:
            return nil
        }
    }

    private static func requestedAction(from spoken: String) -> Substring? {
        let text = singleUtterance(spoken)
        guard let match = text.wholeMatch(of: #/(?<prefix>(?:麻烦|拜托|请)?(?:你)?(?:能不能|可不可以|可以|能)?(?:给我|帮我|为我|陪我)?)(?<action>.+?)(?<suffix>可以吗|好吗|行吗|一下|吧|呀|啊|嘛|吗)?/#) else { return nil }
        let isQuestion = spoken.contains("?") || spoken.contains("？") || match.suffix?.hasSuffix("吗") == true
        let isPoliteRequest = ["请", "麻烦", "拜托", "给我", "帮我", "为我", "陪我"].contains { match.prefix.contains($0) }
            || ["可以吗", "好吗", "行吗"].contains(String(match.suffix ?? ""))
        let hasRequestModal = ["能不能", "可以"].contains { match.prefix.contains($0) }
        guard !isQuestion || isPoliteRequest || hasRequestModal else { return nil }
        return match.action
    }

    private static func validate(_ command: DeepSeekClient.Reply.Command?, spoken: String) -> Command {
        guard let command, let value = command.value else { return .none }
        let text = normalizedCommand(spoken)
        // Reject questions, negations and hypotheticals before allowing model-proposed actions.
        let excluded = ["不要", "不用", "不许", "不想", "不开", "不设", "不切换", "别",
                        "如果", "假如", "假设", "怎么", "为什么", "什么是", "能否", "能不能", "可不可以", "不能", "吗",
                        "听说", "他说", "她说", "我说过", "刚才说", "曾经", "昨天", "或者"]
        guard !excluded.contains(where: text.contains), !spoken.contains("?"), !spoken.contains("？") else {
            return .none
        }
        guard !spoken.contains(where: { "「」『』“”\"".contains($0) }) else { return .none }
        let actionWords = ["开", "关", "切换", "设", "调", "启动", "开始", "给我", "帮我", "提醒我", "叫我"]
        guard actionWords.contains(where: text.contains) else { return .none }
        switch command.type {
        case "setMode":
            switch value {
            case "normal" where text.contains("普通模式"):
                return .setMode(value)
            case "companion" where text.contains("陪伴") || text.contains("关夜灯") || text.contains("关闭夜灯"):
                return .setMode(value)
            case "battery" where text.contains("电量") || text.contains("饱腹度"):
                return .setMode(value)
            case "nightLight" where text.contains("夜灯") && !text.contains("关"):
                return .setMode(value)
            default:
                return .none
            }
        case "nightLightTimer":
            guard text.contains("夜灯"), let minutes = Int(value), [15, 30, 60].contains(minutes),
                  explicitDuration(in: spoken) == minutes * 60 else {
                return .none
            }
            return .nightLightTimer(minutes)
        case "countdown":
            guard text.contains("计时") || text.contains("提醒") || text.contains("叫我"),
                  let seconds = Int(value), (1...7200).contains(seconds),
                  explicitDuration(in: spoken) == seconds else {
                return .none
            }
            return .countdown(seconds)
        default:
            return .none
        }
    }

    private static func explicitDuration(in spoken: String) -> Int? {
        let text = spoken
            .replacingOccurrences(of: "半个小时", with: "30分钟")
            .replacingOccurrences(of: "半小时", with: "30分钟")
            .replacingOccurrences(of: "一刻钟", with: "15分钟")
        let matches = text.matches(of: #/([0-9]+|[零〇一二两兩三四五六七八九十百千]+)\s*(?:个|個)?\s*(小时|小時|分钟|分鐘|分|秒钟|秒鐘|秒)/#)
        guard matches.count == 1, let match = matches.first else { return nil }
        if match.range.lowerBound > text.startIndex {
            let previous = text[text.index(before: match.range.lowerBound)]
            guard !"-−.负負点點".contains(previous) else { return nil }
        }
        let suffix = text[match.range.upperBound...].drop(while: \.isWhitespace)
        if let next = suffix.first, "半又".contains(next) || next.isNumber { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh-CN")
        formatter.numberStyle = .spellOut
        let amount = Int(match.1) ?? formatter.number(from: String(match.1))?.intValue
        guard let amount, (1...7200).contains(amount) else { return nil }
        switch match.2 {
        case "小时", "小時": return amount * 3600
        case "分钟", "分鐘", "分": return amount * 60
        default: return amount
        }
    }
}
