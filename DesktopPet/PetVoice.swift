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
        case play(PetDirector.PlayActivity)
        case face(PetDirector.FaceAction)
    }

    private enum WakeCapture {
        case waiting, addressed, subsequentPhrase
    }

    private(set) var phase: Phase = .idle
    private(set) var conversationActive = false
    private(set) var isCapturingSpeech = false
    private(set) var transcript = ""
    private(set) var replyText: String?
    private(set) var status: String?
    private(set) var mouthOpen = 0.0
    private(set) var hasDeepSeekKey: Bool
    private(set) var hasDoubaoKey: Bool
    private(set) var isPreviewing = false
    private(set) var voiceOutputNotice: String?
    private(set) var speechPermissionDenied = false

    private(set) var isWaitingForWake = false
    private(set) var wakeNotice: String?
    private(set) var lastTranscript: String?

    var canRecord: Bool { phase == .idle && !isPreviewing && !conversationActive }

    @ObservationIgnored var onMarchRequested: (() -> Void)?
    @ObservationIgnored var onReplyExpression: ((PetExpression) -> Void)?
    @ObservationIgnored var onCommand: ((Command) -> Void)?
    @ObservationIgnored var batteryStatusReply: (() -> String?)?
    @ObservationIgnored var canContinueConversation: (() -> Bool)?
    @ObservationIgnored private let audio: SoundSense
    @ObservationIgnored private let client = DeepSeekClient()
    @ObservationIgnored private let doubao = DoubaoVoiceClient()
    @ObservationIgnored private var doubaoPackets: AsyncStream<Data>.Continuation?
    @ObservationIgnored private var doubaoRecognition: Task<Void, Never>?
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var localPlaybackText: String?
    @ObservationIgnored private var outputTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCommand: Command?
    @ObservationIgnored private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var speechTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var speechLimitTask: Task<Void, Never>?
    @ObservationIgnored private var mouthTask: Task<Void, Never>?
    @ObservationIgnored private var captionTask: Task<Void, Never>?
    @ObservationIgnored private var followUpTask: Task<Void, Never>?
    @ObservationIgnored private var utteranceID: ObjectIdentifier?
    @ObservationIgnored private var turnID = UUID()
    @ObservationIgnored private var isHeld = false
    @ObservationIgnored private var pushToTalk = true
    @ObservationIgnored private var isFollowUp = false
    @ObservationIgnored private var greetingContext: String?
    @ObservationIgnored private var recognitionFinished = false
    @ObservationIgnored private var noiseFloor = -60.0
    @ObservationIgnored private var lastAudibleInput: ContinuousClock.Instant?
    @ObservationIgnored private var lastTranscriptChange: ContinuousClock.Instant?
    @ObservationIgnored private var offlineMood: OfflineMood?
    @ObservationIgnored private var history: [DeepSeekClient.Message] = []
    @ObservationIgnored private var persona = Persona(model: "", name: "", personality: "")

    @ObservationIgnored private var wakePersona: Persona?
    @ObservationIgnored private var wakeCapture: WakeCapture?
    @ObservationIgnored private var wakeStartTask: Task<Void, Never>?
    @ObservationIgnored private var wakeSilenceTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTranscript: String?

    init(audio: SoundSense) {
        self.audio = audio
        hasDeepSeekKey = (try? KeychainStore.readAPIKey(account: .deepSeek)) != nil
        hasDoubaoKey = (try? KeychainStore.readAPIKey(account: .doubao)) != nil
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

    enum KeyCheckError: Error {
        case missingKey
        case doubaoCheckFailed(feature: String, error: any Error)
    }

    func checkAPIKey(account: KeychainStore.Account, replacement: String?, model: String) async throws {
        let rawKey = try replacement ?? KeychainStore.readAPIKey(account: account)
        guard let key = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw KeyCheckError.missingKey
        }

        switch account {
        case .deepSeek:
            _ = try await client.reply(apiKey: key, model: model, messages: [
                .init(role: "system", content: "仅输出 JSON 对象，包含非空字符串 reply。"),
                .init(role: "user", content: "请在 reply 中回答：连接正常。")
            ])
        case .doubao:
            do {
                try await doubao.testRecognition(key: key)
            } catch {
                throw KeyCheckError.doubaoCheckFailed(feature: "语音识别", error: error)
            }
            try Task.checkCancellation()
            do {
                _ = try await doubao.synthesize(text: "你好，我是圆圆。", key: key)
            } catch {
                throw KeyCheckError.doubaoCheckFailed(feature: "语音合成", error: error)
            }
        }

        try Task.checkCancellation()
        guard replacement != nil else { return }
        try KeychainStore.saveAPIKey(key, account: account)
        switch account {
        case .deepSeek:
            hasDeepSeekKey = true
            history.removeAll()
        case .doubao:
            hasDoubaoKey = true
        }
    }

    func removeAPIKey(account: KeychainStore.Account) throws {
        try KeychainStore.removeAPIKey(account: account)
        switch account {
        case .deepSeek:
            hasDeepSeekKey = false
            history.removeAll()
        case .doubao:
            hasDoubaoKey = false
        }
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

    func begin(model: String, name: String, personality: String, greeting: String? = nil, pushToTalk: Bool = true) {
        guard canRecord else { return }
        stopWaitingForWake()
        offlineMood = nil
        usePersona(Persona(model: model, name: name, personality: personality))
        dismissConversation()
        greetingContext = greeting
        conversationActive = !pushToTalk
        startTurn(pushToTalk: pushToTalk, followUp: false)
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

    private func startTurn(pushToTalk: Bool, followUp: Bool) {
        let id = UUID()
        turnID = id
        self.pushToTalk = pushToTalk
        isFollowUp = followUp
        transcript = ""
        isHeld = true
        phase = .authorizing
        status = followUp ? "可以接着说" : "正在准备麦克风…"
        recognitionFinished = false
        noiseFloor = -60
        lastAudibleInput = nil
        lastTranscriptChange = nil
        turnTask = Task { [weak self] in
            await self?.authorizeAndListen(id: id)
        }
    }

    func end() {
        isHeld = false
        guard phase == .listening else { return }
        if wakeCapture != nil, transcript.isEmpty {
            endWakeWithoutSpeech()
            return
        }
        wakeSilenceTask?.cancel()
        wakeSilenceTask = nil
        phase = .thinking
        status = "让我想想…"
        speechLimitTask?.cancel()
        speechLimitTask = nil
        finishCapture()

        let id = turnID
        if recognitionFinished {
            submitTranscript(id: id)
        } else {
            speechLimitTask = Task { [weak self] in
                guard let self else { return }
                let timeout: Duration = self.doubaoRecognition == nil ? .seconds(1.2) : .seconds(5)
                do { try await Task.sleep(for: timeout) } catch { return }
                self.submitTranscript(id: id)
            }
        }
    }

    func cancel() {
        offlineMood = nil
        conversationActive = false
        wakeStartTask?.cancel()
        wakeStartTask = nil
        wakeSilenceTask?.cancel()
        wakeSilenceTask = nil
        isWaitingForWake = false
        wakeCapture = nil
        wakeTranscript = nil
        followUpTask?.cancel()
        followUpTask = nil
        turnID = UUID()
        isHeld = false
        turnTask?.cancel()
        turnTask = nil
        speechLimitTask?.cancel()
        speechLimitTask = nil
        clearRecognition()
        utteranceID = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        pendingCommand = nil
        finishSpeaking()
        dismissConversation()
    }

    func dismissConversation() {
        captionTask?.cancel()
        transcript = ""
        replyText = nil
        status = nil
        greetingContext = nil
    }

    private func authorizeAndListen(id: UUID) async {
        let microphoneAllowed = await audio.requestVoicePermission()
        guard isCurrent(id) else { return }
        guard microphoneAllowed else {
            endWithStatus("请在系统设置中允许圆圆使用麦克风。")
            return
        }
        if let key = try? KeychainStore.readAPIKey(account: .doubao), !key.isEmpty {
            guard isHeld else {
                endWithStatus("麦克风已准备好，请再说一次。")
                return
            }
            startDoubaoRecognition(key: key, id: id)
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
            endWithStatus("麦克风已准备好，请再说一次。")
            return
        }
        guard supportsOfflineRecognition else {
            endWithStatus("当前设备的离线普通话识别不可用。")
            return
        }

        guard startRecognition(id: id, reportLevels: !pushToTalk) else {
            endWithStatus("无法启动麦克风，请稍后再试。")
            return
        }
        startListening(id: id)
    }

    private var supportsOfflineRecognition: Bool {
        recognizer?.supportsOnDeviceRecognition == true && recognizer?.isAvailable == true
    }

    private func startRecognition(id: UUID, reportLevels: Bool = false) -> Bool {
        guard let recognizer else { return false }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.contextualStrings = [persona.name, Self.defaultPetName, "嗨，\(persona.name)", "唱首歌", "圆圆进行曲", "跳个舞", "打招呼", "比个心", "点个赞", "吹泡泡", "击个掌", "摇沙锤", "夜灯", "饱腹度", "看着我笑", "闭左眼", "闭右眼", "眯眯眼", "说声早安", "问我吃饭了没"]
        speechRequest = request
        speechTask = recognizer.recognitionTask(with: request, resultHandler: Self.speechHandler { [weak self] update in
            Task { @MainActor [weak self] in
                self?.receive(update, id: id)
            }
        })

        do {
            try audio.startVoiceCapture(request, onLevel: reportLevels ? voiceLevelHandler(id: id) : nil)
            return true
        } catch {
            audio.stopVoiceCapture()
            clearRecognition()
            audio.finishVoice()
            return false
        }
    }

    private func startDoubaoRecognition(key: String, id: UUID) {
        let (stream, packets) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(2048))
        doubaoPackets = packets
        do {
            try audio.startVoiceCapture(packets: packets, onLevel: voiceLevelHandler(id: id))
        } catch {
            clearRecognition()
            audio.finishVoice()
            endWithStatus("无法启动麦克风，请稍后再试。")
            return
        }
        startListening(id: id)
        let client = doubao
        doubaoRecognition = Task { [weak self] in
            do {
                try await client.recognize(key: key, audio: stream) { [weak self] update in
                    await self?.receiveDoubao(update, id: id)
                }
            } catch {
                self?.failDoubaoRecognition(error, id: id)
            }
        }
    }

    private func failDoubaoRecognition(_ error: Error, id: UUID) {
        guard isCurrent(id), doubaoRecognition != nil else { return }
        speechLimitTask?.cancel()
        speechLimitTask = nil
        clearRecognition()
        audio.finishVoice()
        if case DoubaoVoiceClient.VoiceError.serviceCode(let code) = error {
            endWithStatus("豆包语音识别失败（\(code)），请检查服务和 Key。")
        } else {
            endWithStatus("豆包语音识别连接失败，请检查网络和 Key。")
        }
    }

    private func receiveDoubao(_ update: DoubaoVoiceClient.RecognitionUpdate, id: UUID) {
        receive(SpeechUpdate(text: update.text, alternatives: [], finished: update.isFinal), id: id)
        guard isCurrent(id), phase == .listening, !pushToTalk,
              update.isSentenceEnd, !transcript.isEmpty else { return }
        end()
    }

    private func voiceLevelHandler(id: UUID) -> (@Sendable (Double) -> Void)? {
        guard !pushToTalk else { return nil }
        return { [weak self] level in
            Task { @MainActor [weak self] in
                self?.receiveVoiceLevel(level, id: id)
            }
        }
    }

    private func startListening(id: UUID) {
        isCapturingSpeech = true
        phase = .listening
        status = pushToTalk ? "松开发送" : (isFollowUp ? "可以接着说" : "我在听。可以说说你今天的心情。")

        speechLimitTask = Task { [weak self] in
            let started = ContinuousClock.now
            let deadline = started + .seconds(12)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, self.isCurrent(id), self.phase == .listening else { return }
                let now = ContinuousClock.now
                let lastInput = [self.lastAudibleInput, self.lastTranscriptChange].compactMap { $0 }.max()
                let shouldSend = self.doubaoRecognition == nil && !self.pushToTalk && !self.transcript.isEmpty
                    && lastInput.map { now >= $0 + .seconds(1.5) } == true
                let followUpTimedOut = self.isFollowUp && self.transcript.isEmpty && now >= started + .seconds(10)
                if shouldSend || followUpTimedOut || now >= deadline {
                    self.end()
                    return
                }
            }
        }
    }

    private func receiveVoiceLevel(_ level: Double, id: UUID) {
        guard isCurrent(id), isCapturingSpeech else { return }
        if level < noiseFloor || transcript.isEmpty {
            let rate = level < noiseFloor ? 0.12 : 0.02
            noiseFloor = min(-35, max(-75, noiseFloor + (level - noiseFloor) * rate))
        }
        if level > max(-53, noiseFloor + 10) {
            lastAudibleInput = .now
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
        offlineMood = nil
        wakeCapture = .addressed
        wakeTranscript = nil
        transcript = ""
        recognitionFinished = false
        isWaitingForWake = false
        isCapturingSpeech = true
        captionTask?.cancel()
        replyText = nil
        phase = .listening
        scheduleListeningLimit(id: id)
        updateWakeTranscript(phrase, id: id)
    }

    private func updateWakeTranscript(_ phrase: String, id: UUID) {
        guard wakeTranscript != phrase else { return }
        wakeTranscript = phrase
        transcript = phrase
        status = phrase.isEmpty ? "我在听…" : nil
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
        if !transcript.isEmpty {
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
        dismissConversation()
    }

    private func endWithStatus(_ status: String) {
        conversationActive = false
        isHeld = false
        phase = .idle
        self.status = status
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
        guard isCurrent(id), speechTask != nil || doubaoRecognition != nil else { return }
        if let wakeCapture, phase != .thinking {
            receiveWake(update, id: id, capture: wakeCapture)
            return
        }
        if let text = update.text, !text.isEmpty, text != transcript {
            if transcript.isEmpty {
                if isFollowUp { replyText = nil }
                if !pushToTalk { status = "正在听，停顿后自动发送" }
            }
            transcript = text
            lastTranscriptChange = .now
        }
        if update.finished {
            if wakeCapture == .addressed {
                transcript = Self.addressedPhrase(transcript, name: persona.name) ?? ""
            } else {
                transcript = Self.correctMarchTitle(in: transcript, using: update.alternatives, name: persona.name)
            }
            recognitionFinished = true
            if phase == .listening {
                finishCapture()
                if transcript.isEmpty || !pushToTalk { end() }
            } else if phase == .thinking {
                submitTranscript(id: id)
            }
        }
    }

    private func finishCapture() {
        isCapturingSpeech = false
        guard speechRequest != nil || doubaoPackets != nil else { return }
        audio.stopVoiceCapture()
        speechRequest?.endAudio()
        speechRequest = nil
        doubaoPackets?.finish()
        doubaoPackets = nil
    }

    private func clearRecognition() {
        finishCapture()
        speechTask?.cancel()
        speechTask = nil
        doubaoRecognition?.cancel()
        doubaoRecognition = nil
    }

    private func submitTranscript(id: UUID) {
        guard isCurrent(id), phase == .thinking, speechTask != nil || doubaoRecognition != nil else { return }
        speechLimitTask?.cancel()
        speechLimitTask = nil
        clearRecognition()
        wakeCapture = nil
        wakeTranscript = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if isFollowUp {
                conversationActive = false
                audio.finishVoice()
                phase = .idle
                status = nil
                expireCaption()
                scheduleWake()
                return
            }
            speak("我没听清，再说一次吧。", expression: .confused)
            return
        }
        lastTranscript = text
        turnTask = Task { [weak self] in
            await self?.respond(to: text, id: id)
        }
    }

    private func respond(to spoken: String, id: UUID) async {
        guard isCurrent(id) else { return }
        let text = Self.addressedPhrase(spoken, name: persona.name) ?? spoken
        if text.isEmpty {
            speak("我在呢。", expression: .greeting)
            return
        }
        if Self.isMarchRequest(text) {
            dismissConversation()
            finishSpeaking()
            onMarchRequested?()
            return
        }
        if conversationActive, Self.endsConversation(text) {
            conversationActive = false
            speak("好，等你想聊再叫我。", expression: .happy)
            return
        }
        let contextualText = greetingContext.map { "圆圆刚才问候：\($0)\n我的回答：\(text)" } ?? text
        greetingContext = nil
        if Self.isBatteryQuestion(text) {
            let reply = batteryStatusReply?() ?? "切到电量宠物模式，我就能告诉你。"
            rememberTurn(user: contextualText, reply: reply)
            speak(reply, expression: .idle)
            return
        }
        if let localReply = Self.localReply(to: text) {
            rememberTurn(user: contextualText, reply: localReply.text)
            if case .play = localReply.command { conversationActive = false }
            speak(localReply.text, expression: localReply.expression, command: localReply.command)
            return
        }
        let mood = Self.mood(in: text)
        guard let key = try? KeychainStore.readAPIKey(account: .deepSeek), !key.isEmpty else {
            if let mood {
                respondToMood(mood)
                return
            }
            if let reply = Self.offlineChatReply(to: text) {
                speak(reply, expression: .happy)
                return
            }
            if let previous = offlineMood, isFollowUp {
                offlineMood = nil
                let acknowledgement = previous == .joy ? "嗯，我听着呢。你想说多少都可以。" : "我在这里，咱们慢慢来。"
                speak(acknowledgement, expression: .listening)
                return
            }
            speak("我在听。你可以说说今天的心情，也可以叫我比个心。", expression: .listening)
            return
        }

        let user = DeepSeekClient.Message(role: "user", content: contextualText)
        let messages = [DeepSeekClient.Message(role: "system", content: persona.prompt)] + history + [user]
        do {
            let response = try await client.reply(apiKey: key, model: persona.model, messages: messages)
            guard isCurrent(id) else { return }
            let command = Self.validate(response.command, spoken: text)
            if let type = response.command?.type, type != "none", command == .none {
                speak("我没确认你想让我做什么，再说一次吧。", expression: .confused)
                return
            }
            let reply = String(response.reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            let emotion = response.emotion.flatMap { Emotion(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let expression = command == .none ? (emotion ?? .neutral).expression : .happy
            rememberTurn(user: contextualText, reply: reply)
            speak(reply, expression: expression, command: command)
        } catch {
            guard isCurrent(id) else { return }
            if let mood {
                respondToMood(mood)
                return
            }
            conversationActive = false
            switch error {
            case DeepSeekClient.RequestError.httpStatus(401):
                speak("DeepSeek 密钥无效，请检查语音设置。", expression: .confused)
            case DeepSeekClient.RequestError.httpStatus(402):
                speak("DeepSeek 余额不足，请检查账户。", expression: .confused)
            case DeepSeekClient.RequestError.httpStatus(429):
                speak("DeepSeek 现在有点忙，等会儿再聊吧。", expression: .confused)
            case DeepSeekClient.RequestError.invalidResponse:
                audio.finishVoice()
                endWithStatus("已识别到你的话，但聊天服务暂时没能生成回复。")
            case is URLError:
                speak("暂时连不上网络，我还能跳舞和开夜灯。", expression: .confused)
            default:
                speak("DeepSeek 暂时无法回答，请检查语音设置。", expression: .confused)
            }
        }
    }

    private func rememberTurn(user: String, reply: String) {
        history.append(contentsOf: [.init(role: "user", content: user), DeepSeekClient.Reply(reply: reply).historyMessage])
        history = Array(history.suffix(16))
    }

    private static func endsConversation(_ text: String) -> Bool {
        let phrase = singleUtterance(text)
        return ["结束对话", "结束聊天", "不用听了", "先聊到这儿", "先聊到这里"].contains(phrase)
    }

    func announceGreeting(_ text: String) {
        guard canRecord else { return }
        stopWaitingForWake()
        captionTask?.cancel()
        turnID = UUID()
        transcript = ""
        speak(text, expression: .greeting, allowCloud: false)
    }

    private func speak(_ text: String, expression: PetExpression, command: Command = .none, allowCloud: Bool = true) {
        status = nil
        replyText = text
        phase = .speaking
        pendingCommand = command
        switch command {
        case .face: break // The face action starts when the reply audio is ready.
        default: onReplyExpression?(expression)
        }
        playVoice(text, allowCloud: allowCloud)
    }

    private func playVoice(_ text: String, allowCloud: Bool = true) {
        voiceOutputNotice = nil
        let id = turnID
        let cloudKey = allowCloud ? try? KeychainStore.readAPIKey(account: .doubao) : nil
        let client = doubao
        outputTask = Task { [weak self] in
            let cloudAudio: Data?
            if let cloudKey {
                cloudAudio = try? await client.synthesize(text: text, key: cloudKey)
            } else {
                cloudAudio = nil
            }
            guard !Task.isCancelled else { return }
            let data: Data?
            if let cloudAudio {
                data = cloudAudio
            } else {
                data = try? await LocalTTSClient.synthesize(text: text)
            }
            guard let self, self.isCurrent(id) else { return }
            self.outputTask = nil
            if data == nil {
                self.noteVoicePackFallback()
            } else if cloudKey != nil, cloudAudio == nil {
                self.voiceOutputNotice = "豆包语音播报暂不可用，已使用离线音色。"
            }
            self.startPlayback(text, audioData: data)
        }
    }

    private func startPlayback(_ text: String, audioData: Data? = nil) {
        do {
            try audio.prepareVoicePlayback()
        } catch {
            voiceOutputNotice = "无法启动语音播放，请检查音频输出。"
            if !isPreviewing { status = voiceOutputNotice }
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

    func replayReply() {
        guard canRecord, let replyText else { return }
        captionTask?.cancel()
        turnID = UUID()
        phase = .speaking
        status = nil
        playVoice(replyText)
    }

    private func presentReply() {
        guard let command = pendingCommand else { return }
        if case .play = command { return }
        pendingCommand = nil
        onCommand?(command)
    }

    private func noteVoicePackFallback() {
        voiceOutputNotice = "内置语音包暂不可用，正在使用 iPhone 系统音色。"
    }

    private func startLocalPlayback(_ data: Data) -> Bool {
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        player.delegate = self
        player.isMeteringEnabled = true
        player.volume = 1
        player.prepareToPlay()
        guard player.play() else { return false }
        let session = AVAudioSession.sharedInstance()
        if session.outputVolume == 0 {
            status = "媒体音量为零，请按音量加键。"
        } else if let output = session.currentRoute.outputs.first, output.portType != .builtInSpeaker {
            status = "声音正从\(output.portName)播放。"
        }
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

    private func finishSpeaking(resumeConversation: Bool = false) {
        outputTask?.cancel()
        outputTask = nil
        let command = pendingCommand
        pendingCommand = nil
        utteranceID = nil
        stopLocalPlayback()
        speechLimitTask?.cancel()
        speechLimitTask = nil
        mouthTask?.cancel()
        mouthTask = nil
        mouthOpen = 0
        audio.finishVoice()
        isPreviewing = false
        if resumeConversation && conversationActive {
            let id = turnID
            phase = .authorizing
            followUpTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard let self, self.isCurrent(id), self.conversationActive else { return }
                self.followUpTask = nil
                guard self.canContinueConversation?() == true else {
                    self.conversationActive = false
                    self.phase = .idle
                    self.status = nil
                    self.expireCaption()
                    self.scheduleWake()
                    return
                }
                self.startTurn(pushToTalk: false, followUp: true)
            }
            return
        }
        conversationActive = false
        phase = .idle
        if let command, case .play = command { onCommand?(command) }
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
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.phase == .idle else { return }
            self.dismissConversation()
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
        notifySpeechFinished(ObjectIdentifier(utterance), completed: true)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        notifySpeechFinished(ObjectIdentifier(utterance), completed: false)
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
            self.finishSpeaking(resumeConversation: successfully)
        }
    }

    private nonisolated func notifySpeechFinished(_ id: ObjectIdentifier, completed: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.utteranceID == id else { return }
            self.finishSpeaking(resumeConversation: completed)
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
            回复要贴合情绪。难过时先接住感受，不急着安慰成“要开心”，也不催问。用户开心时接住对方分享的具体细节，适合时只问一个自然的后续问题。疲惫时温柔回应，用户生气时平静理解。不要装作记得对方没说过的事。
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

    private enum OfflineMood {
        case low, joy, tired
    }

    private static func mood(in spoken: String) -> OfflineMood? {
        let text = singleUtterance(spoken)
        guard !spoken.contains(where: { "「」『』“”\"？?".contains($0) }) else { return nil }
        // Match explicit descriptions of the speaker's current mood, including a following reason.
        let prefix = #"(?:我)?(?:今天|现在|刚刚|这会儿)?(?:我)?(?:心情)?(?:觉得|有点儿?|很|好|挺|特别|真的|真|太)*"#
        let feelings: [(OfflineMood, String)] = [
            (.low, "(?:不(?:太|怎么)?(?:开心|高兴|快乐|舒服|好)|难过|伤心|心里不好受|心烦|低落)"),
            (.tired, "(?:累|疲惫|疲倦)"),
            (.joy, "(?:开心|高兴|快乐|不错|很好)")
        ]
        // Preserve the negation in “不太开心” instead of treating it as joy.
        let negatedJoy = #/^(?:我)?(?:今天|现在|这会儿)?(?:我)?(?:不太|并不|没有那么)(?:开心|高兴|快乐)(?:了|[，,。；;、！!]|$)/#
        if text.firstMatch(of: negatedJoy) != nil { return .low }
        for (mood, phrase) in feelings {
            let pattern = "^" + prefix + phrase + "(?:了|呀|啊|呢)?(?:[，,。；;、！!]|因为|$)"
            if text.range(of: pattern, options: .regularExpression) != nil { return mood }
        }
        return nil
    }

    private func respondToMood(_ mood: OfflineMood) {
        offlineMood = mood
        let reply: (String, PetExpression) = switch mood {
        case .low: ("听起来今天不好受。我陪你，你想说就说。", .affectionate)
        case .joy: ("真好呀！是什么让你这么开心？我想听。", .happy)
        case .tired: ("辛苦啦，想说的话我听着，也可以一起歇一会儿。", .affectionate)
        }
        speak(reply.0, expression: reply.1, allowCloud: false)
    }

    private static func offlineChatReply(to text: String) -> String? {
        switch normalizedCommand(text) {
        case "你好", "你好呀", "嗨", "哈喽", "hi", "hello": "你好呀！我在这儿陪你。"
        case "早上好", "早安", "早", "早呀": "早上好！今天慢慢来，先做一件想做的事。"
        case "中午好", "午安": "中午好！忙了一上午，记得吃饭。"
        case "吃了", "吃过了", "吃了午饭", "吃过午饭了": "那就好！忙完可以歇一小会儿。"
        case "还没", "没吃", "还没吃", "没吃午饭": "那记得给自己留点吃饭的时间呀。"
        case "下午好": "下午好！陪你伸个懒腰。"
        case "晚上好": "晚上好！今天辛苦啦。"
        case "晚安", "睡了", "去睡了": "晚安，明天见。"
        case "谢谢", "谢谢你", "多谢": "不客气，我就在这儿。"
        default: nil
        }
    }

    private static func localReply(to spoken: String) -> LocalReply? {
        if singleUtterance(spoken).wholeMatch(of: #/(?:请)?问我吃(?:午)?饭了(?:没|吗)/#) != nil {
            return LocalReply(text: PetGreetingPeriod.lunch.greeting, expression: .greeting)
        }
        guard let action = requestedAction(from: spoken) else { return nil }
        if action.wholeMatch(of: #/跳(?:一?[个支段曲])?舞(?:给我看)?/#) != nil {
            return LocalReply(text: "看我的，开跳！", expression: .dancing)
        }
        if action.wholeMatch(of: #/吹(?:(?:一|几)?[个串])?泡泡/#) != nil {
            return LocalReply(text: "泡泡飞起来啦，戳破它们！", expression: .bubbles, command: .play(.bubbles))
        }
        switch action {
        case "看我", "看着我", "看着我笑", "看我笑", "冲我笑", "对我笑":
            return LocalReply(text: "我看到你啦！", expression: .happy, command: .face(.lookAndSmile))
        case "闭左眼", "闭上左眼", "眨左眼", "戳左眼":
            return LocalReply(text: "左眼闭上啦。", expression: .idle, command: .face(.closeEye(.left)))
        case "闭右眼", "闭上右眼", "眨右眼", "戳右眼":
            return LocalReply(text: "右眼闭上啦。", expression: .idle, command: .face(.closeEye(.right)))
        case "眯眼", "眯眯眼", "眯起眼睛":
            return LocalReply(text: "眯起来啦。", expression: .happy, command: .face(.squint))
        case "说早安", "说声早安", "说一声早安":
            return LocalReply(text: PetGreetingPeriod.morning.greeting, expression: .greeting)
        case "问我吃饭了", "问我吃午饭了":
            return LocalReply(text: PetGreetingPeriod.lunch.greeting, expression: .greeting)
        case "击掌", "击个掌", "击一个掌", "跟我击掌", "和我击掌", "来击掌", "来击个掌":
            return LocalReply(text: "来，拍我的手！", expression: .happy, command: .play(.highFive))
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
