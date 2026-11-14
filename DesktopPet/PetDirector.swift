import SwiftUI
import UIKit
import UserNotifications

@MainActor
@Observable
final class PetDirector {
    enum PlayActivity: String, CaseIterable, Identifiable {
        case bubbles = "戳泡泡"
        case highFive = "击掌"

        var id: Self { self }
    }

    struct PlaySession {
        struct Hit {
            let time: TimeInterval
            let center: CGPoint
        }

        let activity: PlayActivity
        let started: TimeInterval
        let fromVision: Bool
        var hits: [Int: Hit] = [:]

        var targetCount: Int { activity == .bubbles ? 4 : 1 }
        var completed: Bool { hits.count == targetCount }
    }

    enum EyeSide: Equatable { case left, right }
    enum FaceAction: Equatable {
        case lookAndSmile, closeEye(EyeSide), squint
    }

    private(set) var playSession: PlaySession?
    private(set) var visionPointer: CGPoint?
    private(set) var visionHighFivePending = false
    private var lastPointerAt: TimeInterval?
    private var visionHintShown = false
    private(set) var visionHint: String?
    private var visionHintUntil: TimeInterval = 0
    let senses = PetSenses()
    let modes = PetModes()
    let focusTimer = PetFocusTimer()
    let audio: SoundSense
    let voice: PetVoice
    @ObservationIgnored var onVoiceGesture: (() -> Void)?

    struct Settings: Equatable {
        var mode: PetMode
        var nightLightMinutes: Int
        var keepAwake: Bool
        var visionEnabled: Bool
        var motion: Bool
        var sound: Bool
        var foreground: Bool
        var background: Bool
        var controlsOpen: Bool
        var expressionSoundsEnabled = false
        var focusing = false
    }

    @ObservationIgnored private var playback = PetPlayback() {
        didSet { updateAnimationCadence(at: now) }
    }
    private(set) var isAnimatingExpression = false
    @ObservationIgnored private let petAudio: PetAudioPlayer
    @ObservationIgnored private var expressionSoundTask: Task<Void, Never>?
    @ObservationIgnored private var expressionSoundPass: SoundPass?
    @ObservationIgnored private var expressionSoundPlaying = false
    @ObservationIgnored private var expressionSoundSamplePlaying = false
    private(set) var isPreviewingExpressionAudio = false
    private(set) var isPlayingMarch = false
    @ObservationIgnored private var marchStartedAt: TimeInterval = 0
    @ObservationIgnored private var marchDuration: TimeInterval = 0
    @ObservationIgnored private let started = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var settings: Settings?
    @ObservationIgnored private var hearingMusic = false
    @ObservationIgnored private var followUp: (expression: PetExpression, at: TimeInterval)?
    private static let rotationKey = "pet.normalExpressionRound"
    @ObservationIgnored private var rotation = PetRotationRound.restored(from: UserDefaults.standard.data(forKey: rotationKey))
    @ObservationIgnored private var quickExpressionIndex: Int?
    @ObservationIgnored private var nextRotationAt: TimeInterval?
    private(set) var expressionShow: (program: PetExpressionShow, index: Int)?
    private(set) var completedExpressionShow: PetExpressionShow?
    @ObservationIgnored private var nextShowStepAt: TimeInterval?
    @ObservationIgnored private var nextAmbientAt: TimeInterval?
    @ObservationIgnored private var lastAmbient: PetExpression?
    @ObservationIgnored private var chargingStartedAt: TimeInterval?
    @ObservationIgnored private var chargeCompletionPending = false
    @ObservationIgnored private var countdown: (id: UUID, deadline: Date)?
    private(set) var notice: String?
    @ObservationIgnored private var noticeUntil: TimeInterval = 0
    @ObservationIgnored private var tapAttention: (point: CGPoint, until: TimeInterval)?
    @ObservationIgnored private var strokeAttention: (point: CGPoint, strength: CGFloat)?
    @ObservationIgnored private var eyePoke: (side: EyeSide, started: TimeInterval)?
    @ObservationIgnored private var position = CGPoint.zero
    @ObservationIgnored private var positionVelocity = CGPoint.zero
    @ObservationIgnored private var lastMotionFrame: TimeInterval?

    private static let ambientExpressions: [PetExpression] = [.peeking, .yawning, .winking]

    private struct SoundPass: Equatable {
        let expression: PetExpression
        let startedAt: TimeInterval
    }

    init() {
        let audio = SoundSense()
        self.audio = audio
        voice = PetVoice(audio: audio)
        petAudio = PetAudioPlayer(audio: audio)

        voice.canContinueConversation = { [weak self] in self?.voiceAvailable == true }
        senses.onVisionPlay = { [weak self] in self?.handleVision($0) }
        senses.onEvent = { [weak self] in self?.handle($0) }
        audio.onEvent = { [weak self] event in
            switch event {
            case .clap: self?.handle(.clap)
            case .doubleClap: self?.handle(.doubleClap)
            case .blow: self?.handle(.blow)
            case .music(let playing): self?.handle(playing ? .musicStarted : .musicStopped)
            }
        }
        modes.onBatteryStateChanged = { [weak self] in self?.refreshChargingState() }
        modes.onReaction = { [weak self] expression in
            guard let self, settings?.foreground == true else { return }
            if expression == .charged {
                chargeCompletionPending = true
                return
            }
            guard reactionsAllowed else { return }
            let time = now
            finishRotation(at: time)
            playback.react(expression, at: time)
        }
    }

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime - started }

    var canUseVoice: Bool { voiceAvailable && voice.canRecord }

    private var voiceAvailable: Bool {
        guard let settings else { return false }
        return expressionShow == nil && settings.foreground && !settings.controlsOpen && settings.mode != .nightLight
            && !senses.isFaceDown
    }

    private var reactionsAllowed: Bool {
        reactionContextAllowed && playSession == nil
    }

    private var reactionContextAllowed: Bool {
        guard let settings else { return false }
        return expressionShow == nil && !isPlayingMarch && settings.foreground && !settings.controlsOpen && settings.mode != .nightLight
            && !settings.focusing && !senses.isFaceDown && voice.phase == .idle
            && !isPetting && !(eyePoke.map { now < $0.started + 0.55 } ?? false)
    }

    private var isCompanionMode: Bool { settings?.mode == .normal || settings?.mode == .companion }

    private var touchAllowed: Bool {
        touchContextAvailable && !playback.isPreviewing(at: now)
    }

    private var touchContextAvailable: Bool {
        guard let settings else { return false }
        return expressionShow == nil && settings.foreground && !settings.controlsOpen && !settings.focusing && !isPlayingMarch
            && settings.mode != .nightLight && !senses.isFaceDown && !modes.isCharging
    }

    var canPet: Bool {
        isCompanionMode && touchAllowed && playSession == nil
    }

    var isPetting: Bool { strokeAttention != nil }

    var canOfferGreeting: Bool {
        isCompanionMode && touchAllowed && reactionsAllowed && voice.canRecord && !playback.hasActiveSelection(at: now)
    }

    func configure(_ settings: Settings) {
        let modeChanged = self.settings?.mode != settings.mode
        let controlsChanged = self.settings?.controlsOpen != settings.controlsOpen
        let enablingVision = settings.visionEnabled && self.settings?.visionEnabled != true
        let startingFocus = settings.focusing && self.settings?.focusing != true
        self.settings = settings
        if !settings.visionEnabled || !settings.foreground || settings.controlsOpen || startingFocus || modeChanged {
            clearVisionPlay()
        }
        if modeChanged || !settings.foreground || settings.controlsOpen || startingFocus {
            clearTouch()
            endPlay()
        }
        let time = now
        finishRotation(at: time)
        if modeChanged || !settings.foreground || settings.controlsOpen || startingFocus {
            stopMarch()
            stopExpressionAudio()
            isPreviewingExpressionAudio = false
            nextRotationAt = nil
            stopExpressionShow()
            if playback.isPlayingRotation(at: time) || playback.isPreviewing(at: time) || playback.isBrowsing(at: time) {
                refreshBaseline(interrupt: true)
            }
        }
        if modeChanged || controlsChanged || !settings.foreground || !settings.expressionSoundsEnabled {
            stopExpressionSoundSample()
        }
        if !settings.expressionSoundsEnabled { stopExpressionAudio() }
        if settings.foreground { voice.refreshPermissions() }
        modes.configure(mode: settings.mode, timerMinutes: settings.nightLightMinutes,
                        active: settings.foreground, keepAwake: settings.keepAwake, screen: windowScene?.screen)
        if settings.background || settings.controlsOpen || !settings.foreground || startingFocus {
            followUp = nil
            nextAmbientAt = nil
        }
        if settings.mode != .battery || settings.foreground { refreshChargingState() }
        if !settings.foreground {
            chargeCompletionPending = false
            if playback.isPlayingChargeCompletion(at: now) { refreshBaseline(interrupt: true) }
        }
        if (settings.mode != .companion || settings.controlsOpen || !settings.foreground),
           playback.isPlayingAmbient(at: now) { refreshBaseline(interrupt: true) }
        let preservePrompt = !settings.background && !settings.controlsOpen
            && (voice.phase == .authorizing || voice.phase == .speaking)
        if (settings.background || settings.controlsOpen || !settings.foreground) && !preservePrompt {
            audio.setEnabled(false)
            voice.cancel()
        }
        updateOrientation()
        configureSenses()
        if enablingVision { visionCameraStatusChanged() }
        updateAmbientAudio()
        refreshBaseline(interrupt: startingFocus)
    }

    func stop() {
        clearTouch()
        playSession = nil
        clearVisionPlay()
        finishRotation(at: now)
        stopMarch()
        stopExpressionAudio()
        stopExpressionSoundSample()
        isPreviewingExpressionAudio = false
        stopExpressionShow()
        settings = nil
        audio.setEnabled(false)
        voice.cancel()
        followUp = nil
        nextRotationAt = nil
        nextAmbientAt = nil
        chargingStartedAt = nil
        chargeCompletionPending = false
        senses.configure(active: false, eyeTracking: false, handGestures: false, motionEnabled: false)
        modes.stop()
    }

    func tick() {
        focusTimer.refresh()
        let time = now
        if let playSession {
            let lastHitAt = playSession.hits.values.map(\.time).max() ?? playSession.started
            if (playSession.completed && time >= lastHitAt + 0.45)
                || (playSession.fromVision && time >= playSession.started + 14) {
                endPlay()
            }
        }

        if settings.map({ $0.visionEnabled || $0.motion }) == true { updateOrientation() }
        finishRotation(at: time)
        modes.tick()
        refreshBaseline()

        if let nextShowStepAt, time >= nextShowStepAt { advanceExpressionShow(at: time) }
        if let next = followUp, time >= next.at {
            followUp = nil
            if reactionsAllowed { playback.react(next.expression, at: time) }
        }
        if let countdown, countdown.deadline <= Date() {
            self.countdown = nil
            if reactionsAllowed {
                playback.react(.celebrate, at: time, priority: .immediate)
            }
            showNotice("倒计时结束")
        }
        if reactionsAllowed, !playback.hasActiveSelection(at: time) {
            if focusTimer.consumeFocusCelebration() {
                playback.react(.celebrate, at: time, priority: .immediate)
            } else if chargeCompletionPending, modes.isFullyCharged {
                chargeCompletionPending = false
                playback.playChargeCompletion(at: time)
            }
        }
        updateAmbientExpression(at: time)
        updateRotation(at: time)
        updateExpressionAudio(at: time)
        if notice != nil, time >= noticeUntil { notice = nil }
        if visionHint != nil, time >= visionHintUntil { visionHint = nil }
    }

    private func updateAnimationCadence(at time: TimeInterval) {
        let animating = playback.hasActiveSelection(at: time) || playback.baseline != .idle
        if animating != isAnimatingExpression { isAnimatingExpression = animating }
    }

    func show(_ expression: PetExpression) {
        endPlay()
        clearTouch()
        finishRotation(at: now)
        stopExpressionSoundSample()
        stopMarch()
        stopExpressionShow()
        followUp = nil
        nextAmbientAt = nil
        nextRotationAt = nil
        quickExpressionIndex = PetExpression.quickExpressions.firstIndex(of: expression)
        playback.show(expression, at: now)
        isPreviewingExpressionAudio = settings?.expressionSoundsEnabled == true
        updateExpressionAudio(at: now)
    }

    var canBrowseExpressions: Bool {
        touchContextAvailable && isCompanionMode && playSession == nil && voice.phase == .idle && !isPetting
    }

    @discardableResult
    func browseExpressions(_ step: Int) -> Bool {
        guard canBrowseExpressions else { return false }
        let expressions = PetExpression.quickExpressions
        let current = quickExpressionIndex ?? (step > 0 ? -1 : 0)
        let index = (current + step + expressions.count) % expressions.count
        quickExpressionIndex = index
        playGestureExpression(expressions[index])
        return true
    }

    @discardableResult
    func celebrateSwipe() -> Bool {
        guard canBrowseExpressions else { return false }
        playGestureExpression(.celebrate)
        return true
    }

    func tapBurstAge(at time: TimeInterval) -> TimeInterval? {
        playback.isTapBurst(at: time) ? playback.elapsed(at: time) : nil
    }

    func isBrowsingExpression(at time: TimeInterval) -> Bool {
        playback.isBrowsing(at: time)
    }

    private func playGestureExpression(_ expression: PetExpression) {
        clearTouch()
        completedExpressionShow = nil
        followUp = nil
        nextAmbientAt = nil
        nextRotationAt = nil
        let time = now
        finishRotation(at: time)
        playback.playQuickExpression(expression, at: time)
        updateExpressionAudio(at: time)
    }

    func respondToTap(toward point: CGPoint = .zero, eye: EyeSide? = nil) {
        guard touchAllowed, playSession == nil, !isPetting, voice.phase == .idle else { return }
        eyePoke = nil
        completedExpressionShow = nil
        followUp = nil
        nextAmbientAt = nil
        nextRotationAt = nil
        let time = now
        finishRotation(at: time)
        tapAttention = (point, time + 0.65)
        let gaze = CGPoint(x: point.x * 16, y: point.y * 9)
        let wasBursting = playback.isTapBurst(at: time)
        let reaction = playback.respondToTap(at: time, toward: gaze)
        if !wasBursting && playback.isTapBurst(at: time) {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
        if reaction == .happy, let eye { eyePoke = (eye, time) }
        updateExpressionAudio(at: time)
    }

    private func pokeEye(_ side: EyeSide) {
        guard touchAllowed, strokeAttention == nil, playSession == nil else { return }
        completedExpressionShow = nil
        followUp = nil
        nextAmbientAt = nil
        clearTouch()
        finishRotation(at: now)
        refreshBaseline(interrupt: true)
        eyePoke = (side, now)
    }

    func playFaceAction(_ action: FaceAction) {
        guard touchAllowed, playSession == nil else { return }
        switch action {
        case .lookAndSmile:
            playback.playTapSmile(at: now, toward: .zero)
        case .closeEye(let side):
            pokeEye(side)
        case .squint:
            playback.playPettingSmile(at: now, startingAt: .pettingSmile)
        }
    }

    func startPlay(_ activity: PlayActivity, fromVision: Bool = false) {
        guard voiceAvailable, settings?.focusing != true, !isPlayingMarch else { return }
        if !fromVision { voice.cancel() }
        visionHighFivePending = false
        clearTouch()
        completedExpressionShow = nil
        followUp = nil
        nextAmbientAt = nil
        nextRotationAt = nil
        let time = now
        finishRotation(at: time)
        if activity == .bubbles {
            playback.react(.bubbles, at: time, priority: .immediate)
        } else {
            refreshBaseline(interrupt: true)
        }
        playSession = PlaySession(activity: activity, started: time, fromVision: fromVision)
    }

    func visionCameraStatusChanged() {
        guard settings?.visionEnabled == true else { return }
        switch senses.cameraStatus {
        case .active:
            if !visionHintShown {
                visionHintShown = true
                showVisionHint("挥挥手，我看得见你")
            }
        case .denied:
            clearVisionPlay()
            showVisionHint("到系统设置里允许圆圆使用相机")
        case .unavailable:
            clearVisionPlay()
            showVisionHint("当前设备无法使用前置相机")
        case .thermal:
            clearVisionPlay()
            showVisionHint("手机有点热，视觉先歇一会儿")
        case .inactive, .starting:
            clearVisionPlay()
        }
    }

    private func configureSenses() {
        guard let settings else { return }
        let cameraAllowed = expressionShow == nil && !isPlayingMarch && !settings.focusing
        senses.configure(active: settings.foreground && !settings.controlsOpen && !settings.focusing,
                         eyeTracking: cameraAllowed && settings.visionEnabled,
                         handGestures: cameraAllowed && settings.visionEnabled,
                         motionEnabled: settings.motion && !settings.focusing,
                         suppressCamera: modes.sensorsSuppressed,
                         visionPlayEnabled: cameraAllowed && settings.visionEnabled)
    }

    private func clearVisionPlay() {
        if playSession?.fromVision == true { playSession = nil }
        visionPointer = nil
        visionHighFivePending = false
        lastPointerAt = nil
        visionHint = nil
        visionHintShown = false
    }

    private func showVisionHint(_ text: String) {
        visionHint = text
        visionHintUntil = now + 4
    }

    private func handleVision(_ frame: VisionPlayFrame) {
        guard !isPlayingMarch, settings?.visionEnabled == true, voiceAvailable, settings?.focusing != true,
              voice.phase == .idle, !isPetting, !playback.isPreviewing(at: now) else { return }
        let time = now
        if let tip = frame.pointer {
            // The camera buffers are upright and unmirrored. Use selfie coordinates on screen.
            let target = CGPoint(x: 1 - tip.x, y: 1 - tip.y)
            if let current = visionPointer {
                visionPointer = CGPoint(x: current.x + (target.x - current.x) * 0.65,
                                        y: current.y + (target.y - current.y) * 0.65)
            } else {
                visionPointer = target
            }
            lastPointerAt = time
        } else if let lastPointerAt, time - lastPointerAt > 0.18 {
            visionPointer = nil
        }
        switch frame.trigger {
        case .pointReady:
            if playSession == nil || playSession?.activity == .highFive && playSession?.fromVision == true {
                startPlay(.bubbles, fromVision: true)
                visionHint = nil
            }
        case .palmReady:
            if playSession == nil {
                startPlay(.highFive, fromVision: true)
                showVisionHint("手掌往前推一下")
            }
        case .palmPushed:
            if let session = playSession, session.activity == .highFive, !session.completed {
                // The view resolves the hit against the same geometry that draws the palm.
                visionHighFivePending = true
                visionHint = nil
            }
        case nil:
            break
        }
    }

    func consumeVisionHighFive(at center: CGPoint) {
        guard visionHighFivePending else { return }
        visionHighFivePending = false
        guard playSession?.activity == .highFive else { return }
        hitPlayTarget(0, at: center)
    }

    func hitPlayTarget(_ index: Int, at center: CGPoint) {
        guard voiceAvailable, settings?.focusing != true, var session = playSession, session.hits[index] == nil,
              (0..<session.targetCount).contains(index) else { return }
        let time = now
        session.hits[index] = PlaySession.Hit(time: time, center: center)
        playSession = session
        if session.completed {
            playback.react(session.activity == .bubbles ? .delighted : .happy, at: time, priority: .immediate)
        }
    }

    func pet(toward point: CGPoint, distance: CGFloat) {
        guard canPet else { return }
        if strokeAttention == nil {
            completedExpressionShow = nil
            finishRotation(at: now)
            clearTouch()
        }
        nextAmbientAt = nil
        followUp = nil
        strokeAttention = (point, min(1, max(strokeAttention?.strength ?? 0, 0.48 + distance / 115)))
    }

    func endPetting(completed: Bool) {
        guard let strokeAttention else { return }
        self.strokeAttention = nil
        guard completed, canPet else { return }
        var pose = pettingPose(strength: strokeAttention.strength)
        pose.lookX = strokeAttention.point.x * 70
        pose.lookY = strokeAttention.point.y * 25
        if voice.phase == .idle {
            let time = now
            playback.playPettingSmile(at: time, startingAt: pose)
            updateAnimationCadence(at: time)
        } else {
            tapAttention = (strokeAttention.point, now + 0.65)
        }
    }

    func endPlay() {
        playSession = nil
        visionHighFivePending = false
    }

    private func clearTouch() {
        playback.resetTapSequence()
        tapAttention = nil
        strokeAttention = nil
        eyePoke = nil
    }

    func playVoiceReply(_ expression: PetExpression) {
        finishRotation(at: now)
        followUp = nil
        nextAmbientAt = nil
        nextRotationAt = nil
        refreshBaseline(interrupt: expression == .idle)
        guard expression != .idle else { return }
        let time = now
        playback.react(expression, at: time, priority: .immediate)
        updateAnimationCadence(at: time)
    }

    func expression(at time: TimeInterval) -> PetExpression {
        isPlayingMarch ? .musical : playback.expression(at: time)
    }
    func expressionVariant(at time: TimeInterval) -> PetExpressionVariant { playback.variant(at: time) }
    func effectElapsed(at time: TimeInterval) -> TimeInterval {
        isPlayingMarch ? marchElapsed(at: time) : playback.effectElapsed(at: time)
    }
    func faceScale(at time: TimeInterval, motionEnabled: Bool) -> CGFloat {
        guard motionEnabled, settings?.mode != .nightLight || expressionShow != nil else { return 1 }
        return isPlayingMarch ? 1 : playback.faceScale(at: time)
    }

    func isPreviewingExpression(at time: TimeInterval) -> Bool { playback.isPreviewing(at: time) }
    func isPerformingExpression(at time: TimeInterval) -> Bool { playback.isPlayingRotation(at: time) }
    func glow(at time: TimeInterval) -> [PetPlayback.GlowLayer] { playback.glow(at: time) }

    func startExpressionShow(_ program: PetExpressionShow) {
        guard settings?.foreground == true, settings?.focusing != true, let expression = program.expressions.first else { return }
        stopMarch()
        stopExpressionAudio()
        stopExpressionSoundSample()
        isPreviewingExpressionAudio = false
        let time = now
        finishRotation(at: time)
        completedExpressionShow = nil
        followUp = nil
        nextAmbientAt = nil
        nextRotationAt = nil
        clearTouch()
        endPlay()
        expressionShow = (program, 0)
        voice.cancel()
        modes.setExpressionShowActive(true)
        configureSenses()
        updateAmbientAudio()
        refreshBaseline()
        playback.playShowStep(expression, at: time)
        nextShowStepAt = time + expression.motionDuration + program.pauseBetweenSteps
        updateExpressionAudio(at: time)
    }

    func skipExpressionShowStep() {
        advanceExpressionShow(at: now)
    }

    func stopExpressionShow() {
        completedExpressionShow = nil
        guard expressionShow != nil else { return }
        stopExpressionAudio()
        expressionShow = nil
        nextShowStepAt = nil
        modes.setExpressionShowActive(false)
        configureSenses()
        updateAmbientAudio()
        refreshBaseline(interrupt: true)
    }

    private func advanceExpressionShow(at time: TimeInterval) {
        guard let show = expressionShow else { return }
        let index = show.index + 1
        let expressions = show.program.expressions
        guard index < expressions.count else {
            stopExpressionShow()
            completedExpressionShow = show.program
            return
        }
        let expression = expressions[index]
        expressionShow = (show.program, index)
        playback.playShowStep(expression, at: time)
        let pause = index == expressions.count - 1 ? 0 : show.program.pauseBetweenSteps
        nextShowStepAt = time + expression.motionDuration + pause
        updateExpressionAudio(at: time)
    }

    func pose(at time: TimeInterval, motionEnabled: Bool) -> PetPose {
        if isPlayingMarch {
            return Self.marchPose(at: marchElapsed(at: time), duration: marchDuration, motionEnabled: motionEnabled)
        }
        var pose = motionEnabled ? playback.pose(at: time) : playback.stillPose(at: time)
        if expressionShow != nil { return pose }
        if let strokeAttention, canPet {
            pose = pettingPose(strength: strokeAttention.strength)
            if motionEnabled {
                pose.lookX = strokeAttention.point.x * 70
                pose.lookY = strokeAttention.point.y * 25
            }
        } else if motionEnabled && settings?.mode != .nightLight {
            let gaze = senses.handTarget == nil ? senses.gaze : CGPoint(x: position.x * 9, y: position.y * 5)
            pose.lookX += gaze.x
            pose.lookY += gaze.y
            pose.turn = max(-1, min(1, pose.turn + gaze.x / 70))
        }
        if let eyePoke, time - eyePoke.started < 0.55 {
            applyEyePoke(to: &pose, side: eyePoke.side, age: time - eyePoke.started, motionEnabled: motionEnabled)
        }
        pose.brightness *= brightness(motionEnabled: motionEnabled)
        if voice.phase == .speaking {
            pose.mouth = max(pose.mouth, 0.85)
            pose.mouthOpen = max(pose.mouthOpen, motionEnabled ? CGFloat(voice.mouthOpen) : 0.3)
        }
        return pose
    }

    private func applyEyePoke(to pose: inout PetPose, side: EyeSide, age: TimeInterval, motionEnabled: Bool) {
        func ease(_ value: TimeInterval) -> CGFloat {
            let t = CGFloat(min(1, max(0, value)))
            return t * t * (3 - 2 * t)
        }
        let squeeze = ease(age / 0.07) * (1 - ease((age - 0.13) / 0.32))
        let shut = EyePose(width: 0.9, height: 0.10, curve: 18, lidWeight: 8.5)
        if side == .left {
            pose.left = pose.left.blended(with: shut, progress: squeeze)
        } else {
            pose.right = pose.right.blended(with: shut, progress: squeeze)
        }
        if motionEnabled {
            let direction: CGFloat = side == .left ? 1 : -1
            pose.lookX += direction * 39 * squeeze
            pose.lookY += 9 * squeeze
            pose.turn += direction * 0.28 * squeeze
        }
    }

    private func pettingPose(strength: CGFloat) -> PetPose {
        PetExpression.idle.pose.blended(with: .pettingSmile, progress: strength)
    }

    private func marchElapsed(at time: TimeInterval) -> TimeInterval {
        petAudio.currentTime ?? max(0, time - marchStartedAt)
    }

    static func marchPose(at time: TimeInterval, duration: TimeInterval, motionEnabled: Bool) -> PetPose {
        let eye = EyePose(width: 0.78, height: 0.21, curve: -78, lift: -6, lidWeight: 10)
        var pose = PetPose(left: eye, right: eye, accent: .marchGuitar)
        guard motionEnabled else { return pose }

        func ease(_ fraction: Double) -> CGFloat {
            let progress = min(1, max(0, fraction))
            return CGFloat(progress * progress * (3 - 2 * progress))
        }

        let beat = PetPose.marchBeat(at: time)
        let entrance = ease(time / 0.44)
        let exit = ease((duration - time) / 0.74)
        let strength = entrance * exit
        // Travel from one side to the other every two beats; the face and guitar share this transform.
        let sway = CGFloat(sin(beat * .pi / 2)) * strength
        let beatPhase = beat.truncatingRemainder(dividingBy: 1)
        let strum = CGFloat(max(0, 1 - abs(beatPhase - 0.12) / 0.31))
        pose.turn = sway * 0.92
        pose.lookX = sway * 82
        pose.bounce = -3.5 * strum * strength
        pose.left.width *= 1 - sway * 0.11
        pose.right.width *= 1 + sway * 0.11
        return pose
    }

    func travel(at time: TimeInterval, motionEnabled: Bool) -> CGPoint {
        guard motionEnabled, expressionShow == nil, !isPlayingMarch, settings?.mode != .nightLight, !senses.isFaceDown else {
            position = .zero
            positionVelocity = .zero
            lastMotionFrame = nil
            tapAttention = nil
            return .zero
        }

        let target: CGPoint
        if let tapAttention, time < tapAttention.until {
            target = tapAttention.point
        } else if let hand = senses.handTarget {
            target = CGPoint(x: bounded(hand.x * 1.5), y: bounded(hand.y * 1.5))
        } else if let face = senses.faceTarget {
            target = CGPoint(x: bounded(face.x) * 0.55, y: bounded(face.y) * 0.35)
        } else {
            target = .zero
        }

        let previous = lastMotionFrame ?? (time - 1.0 / 30)
        guard time > previous else { return position }
        // Closed-form spring: advance by real time so it settles just as fast at the idle cadence.
        let step = CGFloat(min(time - previous, 0.2))
        lastMotionFrame = time
        let decay = exp(-18 * step)
        func advance(_ value: inout CGFloat, velocity: inout CGFloat, toward target: CGFloat) {
            let distance = value - target
            let slope = velocity + 18 * distance
            value = target + (distance + slope * step) * decay
            velocity = (velocity - 18 * slope * step) * decay
        }
        advance(&position.x, velocity: &positionVelocity.x, toward: target.x)
        advance(&position.y, velocity: &positionVelocity.y, toward: target.y)
        return CGPoint(x: bounded(position.x), y: bounded(position.y))
    }

    private func bounded(_ value: CGFloat) -> CGFloat { min(1, max(-1, value)) }

    func brightness(motionEnabled: Bool) -> CGFloat {
        if expressionShow != nil { return 1 }
        let dim = senses.isFaceDown && settings?.mode != .nightLight ? 0.28 : 1.0
        return dim * modes.brightness(motionEnabled: motionEnabled)
    }

    func voicePhaseChanged() {
        let time = now
        finishRotation(at: time)
        nextAmbientAt = nil
        nextRotationAt = nil
        if voice.phase != .idle {
            stopMarch()
            stopExpressionAudio()
            stopExpressionSoundSample()
            completedExpressionShow = nil
        }
        let interrupt = voice.isCapturingSpeech || voice.phase == .thinking
            || (voice.phase == .authorizing && (playback.isPlayingAmbient(at: time) || playback.isPlayingRotation(at: time)))
        if interrupt { followUp = nil }
        refreshBaseline(interrupt: interrupt)
    }

    func prepareForVoiceInput() {
        endPlay()
        clearTouch()
        visionPointer = nil
        visionHint = nil
        stopMarch()
        stopExpressionAudio()
        stopExpressionSoundSample()
        if playback.isPreviewing(at: now) {
            isPreviewingExpressionAudio = false
            refreshBaseline(interrupt: true)
        }
    }

    @discardableResult
    func playMarch() -> Bool {
        guard reactionsAllowed, !voice.isPreviewing else { return false }
        let time = now
        finishRotation(at: time)
        stopExpressionAudio()
        stopExpressionSoundSample()
        voice.pauseWakeForExpressionAudio()
        endPlay()
        clearTouch()
        isPlayingMarch = true
        configureSenses()
        guard let duration = petAudio.play(.march, onFinish: { [weak self] in self?.stopMarch() }) else {
            stopMarch()
            showNotice("圆圆暂时唱不了，稍后再试试。")
            return false
        }
        marchStartedAt = now
        marchDuration = duration
        modes.setMarchActive(true)
        followUp = nil
        nextAmbientAt = nil
        nextRotationAt = nil
        completedExpressionShow = nil
        tapAttention = nil
        playback.playMarch(duration: duration, at: marchStartedAt)
        return true
    }

    func stopMarch() {
        guard isPlayingMarch else { return }
        isPlayingMarch = false
        configureSenses()
        marchDuration = 0
        modes.setMarchActive(false)
        petAudio.stop()
        refreshBaseline(interrupt: true)
    }

    @discardableResult
    func previewExpressionSound() -> Bool {
        guard let settings, settings.foreground, settings.controlsOpen, settings.expressionSoundsEnabled else { return false }
        voice.stopPreview()
        guard voice.phase == .idle else { return false }
        stopMarch()
        stopExpressionAudio()
        stopExpressionSoundSample()
        voice.pauseWakeForExpressionAudio()
        expressionSoundSamplePlaying = true
        if petAudio.play(.expression(.bubbles), onFinish: { [weak self] in self?.expressionSoundSamplePlaying = false }) != nil {
            return true
        }
        expressionSoundSamplePlaying = false
        return false
    }

    private func updateExpressionAudio(at time: TimeInterval) {
        updateAnimationCadence(at: time)
        let preview = playback.isPreviewing(at: time) && settings?.expressionSoundsEnabled == true
        if isPreviewingExpressionAudio != preview { isPreviewingExpressionAudio = preview }
        guard let pass = playback.activeExpressionPass(at: time) else {
            changeExpressionSoundPass(to: nil)
            return
        }
        let current = SoundPass(expression: pass.expression, startedAt: pass.startedAt)
        guard current != expressionSoundPass else { return }
        // True idle, recording and thinking use the baseline; their acting versions have a playback pass.
        let delay = expressionSoundDelay(for: pass.expression)
        let explicit = preview || expressionShow != nil
        let deadline = pass.startedAt + delay + (explicit ? 0.36 : 0.18)
        let allowed = expressionAudioAllowed(at: time)
        guard !explicit || allowed || time >= deadline else {
            if expressionSoundPlaying || expressionSoundTask != nil { stopExpressionAudio() }
            return
        }
        changeExpressionSoundPass(to: current)
        guard allowed, time < deadline else { return }
        let wait = max(0, pass.startedAt + delay - now)
        expressionSoundTask = Task { [weak self] in
            if wait > 0 {
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            }
            guard !Task.isCancelled, let self else { return }
            let time = self.now
            self.expressionSoundTask = nil
            guard let pass = self.playback.activeExpressionPass(at: time),
                  current == SoundPass(expression: pass.expression, startedAt: pass.startedAt),
                  time < deadline,
                  self.expressionAudioAllowed(at: time) else { return }
            self.voice.pauseWakeForExpressionAudio()
            self.expressionSoundPlaying = true
            if self.petAudio.play(.expression(pass.expression), onFinish: { [weak self] in self?.expressionSoundPlaying = false }) == nil {
                self.expressionSoundPlaying = false
            }
        }
    }

    private func expressionSoundDelay(for expression: PetExpression) -> TimeInterval {
        switch expression {
        case .angry, .celebrate, .delighted, .happy, .listening: 0.18
        case .cool, .surprised, .confused, .dancing, .affectionate, .hungry: 0.25
        case .proud, .shy, .greeting, .laughing, .musical, .dizzy, .charged: 0.34
        case .winking, .thumbsUp, .bubbles, .freezing, .maracas, .thinking, .curious: 0.42
        case .sad, .munching, .handHeart, .kiss: 0.51
        case .crying: 0.67
        case .peeking: 0.71
        case .charging: 0.79
        case .yawning: 0.92
        case .sleepy: 1.16
        case .idle: 1.70
        }
    }

    private func expressionAudioAllowed(at time: TimeInterval) -> Bool {
        guard let settings, settings.expressionSoundsEnabled, settings.foreground, !settings.controlsOpen,
              !senses.isFaceDown, !isPlayingMarch, !playback.isPlayingAmbient(at: time),
              voice.phase == .idle, !voice.isPreviewing else { return false }
        return settings.mode != .nightLight || expressionShow != nil || playback.isPreviewing(at: time)
    }

    private func changeExpressionSoundPass(to pass: SoundPass?) {
        guard pass != expressionSoundPass else { return }
        stopExpressionAudio()
        expressionSoundPass = pass
    }

    private func stopExpressionAudio() {
        expressionSoundTask?.cancel()
        expressionSoundTask = nil
        if expressionSoundPlaying {
            expressionSoundPlaying = false
            petAudio.stop()
        }
    }

    private func stopExpressionSoundSample() {
        guard expressionSoundSamplePlaying else { return }
        expressionSoundSamplePlaying = false
        petAudio.stop()
    }

    func scheduleCountdown(seconds: Int) {
        guard (1...7200).contains(seconds) else { return }
        let center = UNUserNotificationCenter.current()
        if let countdown { center.removePendingNotificationRequests(withIdentifiers: [countdown.id.uuidString]) }
        let id = UUID()
        let deadline = Date().addingTimeInterval(Double(seconds))
        countdown = (id, deadline)

        Task {
            do {
                let authorized = try await center.requestAuthorization(options: [.alert, .sound])
                guard countdown?.id == id else { return }
                guard authorized else {
                    showNotice("倒计时已开始，可在圆圆的主画面查看")
                    return
                }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return }
                let content = UNMutableNotificationContent()
                content.title = PetVoice.defaultPetName
                content.body = "倒计时结束啦"
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
                try await center.add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: trigger))
                if let current = countdown, current.id != id {
                    center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
                }
            } catch {
                if countdown?.id == id { showNotice("倒计时已开始，可在圆圆的主画面查看") }
            }
        }
    }

    func countdownText() -> String? {
        guard let countdown else { return nil }
        let seconds = max(0, Int(ceil(countdown.deadline.timeIntervalSinceNow)))
        return "倒计时 " + Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }

    private var windowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.windows.contains(where: \.isKeyWindow) }
            ?? scenes.first { $0.activationState == .foregroundActive }
    }

    func updateOrientation() {
        guard let windowScene else { return }
        let orientation = if #available(iOS 26.0, *) {
            windowScene.effectiveGeometry.interfaceOrientation
        } else {
            windowScene.interfaceOrientation
        }
        if senses.setOrientation(orientation) {
            visionPointer = nil
        }
    }

    private func updateAmbientAudio() {
        let enabled = settings.map {
            expressionShow == nil && $0.foreground && !$0.controlsOpen && !$0.focusing && $0.sound
                && !modes.sensorsSuppressed && !senses.isFaceDown
        } ?? false
        if !enabled { hearingMusic = false }
        audio.setEnabled(enabled)
    }

    private func refreshBaseline(interrupt: Bool = false) {
        let baseline: PetExpression
        if expressionShow != nil {
            baseline = .idle
        } else if settings?.mode == .nightLight {
            baseline = modes.baseline ?? .idle
        } else if senses.isFaceDown {
            baseline = .sleepy
        } else if voice.isCapturingSpeech {
            baseline = .listening
        } else if voice.phase == .thinking {
            baseline = .thinking
        } else if settings?.focusing == true {
            baseline = .idle
        } else {
            baseline = modes.baseline ?? (hearingMusic ? .musical : .idle)
        }
        let time = now
        playback.setBaseline(baseline, at: time,
                             motionStartedAt: baseline == .charging ? chargingStartedAt : nil, interrupt: interrupt)
        updateAnimationCadence(at: time)
    }

    private func refreshChargingState() {
        if modes.isCharging {
            chargingStartedAt = chargingStartedAt ?? now
        } else {
            chargingStartedAt = nil
        }
        let cancelCompletion = !modes.isFullyCharged
        if cancelCompletion { chargeCompletionPending = false }
        refreshBaseline(interrupt: cancelCompletion && playback.isPlayingChargeCompletion(at: now))
    }

    private func updateAmbientExpression(at time: TimeInterval) {
        guard reactionsAllowed, settings?.mode == .companion, playback.baseline == .idle,
              !playback.hasActiveSelection(at: time), followUp == nil else {
            nextAmbientAt = nil
            return
        }
        guard let nextAmbientAt else {
            self.nextAmbientAt = time + .random(in: 45...90)
            return
        }
        guard time >= nextAmbientAt,
              let expression = Self.ambientExpressions.filter({ $0 != lastAmbient }).randomElement() else { return }
        self.nextAmbientAt = nil
        lastAmbient = expression
        playback.playAmbient(expression, at: time)
    }

    private func finishRotation(at time: TimeInterval) {
        guard let expression = playback.takeCompletedRotation(at: time) else { return }
        rotation.complete(expression)
        if let data = try? JSONEncoder().encode(rotation) {
            UserDefaults.standard.set(data, forKey: Self.rotationKey)
        }
    }

    private func playRotation(at time: TimeInterval) {
        nextRotationAt = nil
        playback.playRotation(rotation.nextExpression, variant: rotation.variant, at: time)
    }

    private func updateRotation(at time: TimeInterval) {
        guard settings?.mode == .normal, reactionsAllowed, followUp == nil else {
            nextRotationAt = nil
            return
        }
        guard !playback.hasActiveSelection(at: time) else { return }
        if playback.baseline == .idle {
            if let nextRotationAt {
                if time >= nextRotationAt { playRotation(at: time) }
            } else {
                nextRotationAt = time + .random(in: 3...5)
            }
        } else {
            nextRotationAt = nil
        }
    }

    private func handle(_ stimulus: PetStimulus) {
        switch stimulus {
        case .wave, .closePalm:
            guard reactionContextAllowed, !playback.isPreviewing(at: now) else { return }
            if case .closePalm = stimulus, !voice.canRecord { return }
            if let playSession {
                // Holding the palm may have offered a high five before the intent was clear.
                guard playSession.fromVision, playSession.activity == .highFive, playSession.hits.isEmpty else { return }
                endPlay()
            }
            if case .wave = stimulus {
                let time = now
                finishRotation(at: time)
                followUp = nil
                nextRotationAt = nil
                playback.react(.greeting, at: time, priority: .immediate)
            } else {
                onVoiceGesture?()
            }
            return
        default: break
        }
        let time = now
        if case .faceDown = stimulus {
            clearTouch()
            endPlay()
            clearVisionPlay()
            stopMarch()
            stopExpressionAudio()
            stopExpressionSoundSample()
        }
        guard expressionShow == nil else { return }
        finishRotation(at: time)
        nextAmbientAt = nil
        nextRotationAt = nil
        switch stimulus {
        case .faceDown:
            followUp = nil
            updateAmbientAudio()
            voice.cancel()
            refreshBaseline(interrupt: true)
        case .faceUp:
            updateAmbientAudio()
            refreshBaseline()
            if reactionsAllowed { playback.react(.surprised, at: time) }
        case .musicStarted, .musicStopped:
            if case .musicStarted = stimulus { hearingMusic = true } else { hearingMusic = false }
            let interrupt = !expressionSoundPlaying && (playback.isPlayingAmbient(at: time) || playback.isPlayingRotation(at: time))
            refreshBaseline(interrupt: interrupt)
        default:
            guard reactionsAllowed else { return }
            switch stimulus {
            case .faceReturned: react(.greeting, then: .happy, at: time)
            case .faceLost: playback.react(.peeking, at: time)
            case .searching: playback.react(.curious, at: time)
            case .thumbsUp, .heart:
                guard !playback.isPreviewing(at: time) else { return }
                followUp = nil
                if case .thumbsUp = stimulus {
                    playback.react(.thumbsUp, at: time, priority: .immediate)
                } else {
                    playback.react(.affectionate, at: time, priority: .immediate)
                }
            case .shake: playback.react(.dizzy, at: time)
            case .pickedUp: react(.surprised, then: .greeting, at: time)
            case .clap: playback.react(.surprised, at: time)
            case .doubleClap: playback.react(.dancing, at: time)
            case .blow: playback.react(.freezing, at: time, usesFreezingProps: false)
            default: break
            }
        }
    }

    private func react(_ expression: PetExpression, then next: PetExpression, at time: TimeInterval) {
        if playback.react(expression, at: time) {
            followUp = (next, time + expression.motionDuration)
        }
    }

    private func showNotice(_ message: String) {
        notice = message
        noticeUntil = now + 6
    }
}
