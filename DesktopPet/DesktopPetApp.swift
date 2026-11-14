import SwiftUI
import UIKit

@main
struct DesktopPetApp: App {
    @UIApplicationDelegateAdaptor(PetAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            PetScreen()
                .preferredColorScheme(.dark)
        }
    }
}

struct PetScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @AppStorage(PetScreenOrientation.storageKey) private var screenOrientation: PetScreenOrientation = .automatic
    @AppStorage("pet.showSettingsButton") private var showSettingsButton = false
    @AppStorage("pet.showVoiceButton") private var showVoiceButton = false
    @AppStorage("pet.showPetCaption") private var showPetCaption = true
    @AppStorage("pet.proactiveGreetings") private var proactiveGreetings = true
    @AppStorage("pet.lastGreetingAt") private var lastGreetingAt: Double = 0
    @AppStorage("pet.keepAwake") private var keepAwake = false
    @AppStorage("pet.showMouth") private var showMouth = false
    @AppStorage("pet.mode") private var mode: PetMode = .normal
    @AppStorage("pet.nightLightMinutes") private var nightLightMinutes = 0
    @AppStorage("pet.eyeTracking") private var eyeTracking = false
    @AppStorage("pet.handGestures") private var handGestures = false
    @AppStorage("pet.motion") private var motion = false
    @AppStorage("pet.soundReactions") private var sound = false
    @AppStorage("pet.expressionSounds") private var expressionSounds = false
    @AppStorage("pet.voiceWakeEnabled") private var voiceWakeEnabled = false
    @AppStorage("pet.deepSeekModel") private var model = DeepSeekClient.defaultModel
    @AppStorage("pet.name") private var petName = PetVoice.defaultPetName
    @AppStorage("pet.personality") private var personality = "元气"
    @AppStorage("pet.customPersonality") private var customPersonality = ""
    @State private var director = PetDirector()
    @State private var showControls = false
    @AppStorage("pet.visionEnabled") private var visionEnabled = false
    @State private var messageAlertID: UUID?
    @State private var activityPath: [ActivityPage] = []
    @State private var pendingExpression: PetExpression?
    @State private var pendingExpressionShow: PetExpressionShow?
    @State private var pendingPlayActivity: PetDirector.PlayActivity?
    @State private var pendingMarch = false
    @State private var expressionSoundPreviewFailed = false
    @State private var keyInputs: [KeychainStore.Account: String] = [:]
    @State private var keyMessages: [KeychainStore.Account: String] = [:]
    @State private var checkingKey: KeychainStore.Account?
    @State private var keyCheckTask: Task<Void, Never>?
    @GestureState private var faceDragActive = false
    @GestureState private var micHeld = false
    @State private var micStarted = false

    private enum ActivityPage: Hashable {
        case focus, game
    }

    private var displayName: String {
        let name = petName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? PetVoice.defaultPetName : name
    }

    private var settings: PetDirector.Settings {
        PetDirector.Settings(mode: mode, nightLightMinutes: nightLightMinutes, keepAwake: keepAwake,
                             eyeTracking: eyeTracking, handGestures: handGestures, visionEnabled: visionEnabled, motion: motion, sound: sound,
                             foreground: scenePhase == .active, background: scenePhase == .background,
                             controlsOpen: showControls, expressionSoundsEnabled: expressionSounds,
                             focusing: director.focusTimer.isFocusing)
    }

    private var selectedPersonality: String {
        let custom = customPersonality.trimmingCharacters(in: .whitespacesAndNewlines)
        return personality == "自定义" ? (custom.isEmpty ? "元气" : custom) : personality
    }

    private struct WakeSettings: Equatable {
        let enabled: Bool
        let model: String
        let name: String
        let personality: String
    }

    private var wakeSettings: WakeSettings {
        WakeSettings(enabled: voiceWakeEnabled && scenePhase == .active && !showControls && !director.focusTimer.isFocusing
                     && voiceAvailable && !director.isPlayingMarch && !director.isPreviewingExpressionAudio,
                     model: model, name: displayName, personality: selectedPersonality)
    }

    private var expressionShowActive: Bool { director.expressionShow != nil }

    var body: some View {
        GeometryReader { geometry in
            let portrait = geometry.size.height > geometry.size.width
            let insets = geometry.safeAreaInsets
            let left = layoutDirection == .leftToRight ? insets.leading : insets.trailing
            let right = layoutDirection == .leftToRight ? insets.trailing : insets.leading
            // The face is centered in the safe area while the glow spans the full display.
            let safeAreaOffset = CGSize(width: (left - right) / 2, height: (insets.top - insets.bottom) / 2)
            ZStack {
                Color(white: 0.035)
                    .ignoresSafeArea()

                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: scenePhase != .active || showControls)) { _ in
                    let now = director.now
                    let expression = director.expression(at: now)
                    let variant = director.expressionVariant(at: now)
                    let isPreviewing = director.isPreviewingExpression(at: now)
                    let isPerforming = director.isPerformingExpression(at: now)
                    let isActing = isPerforming || expressionShowActive
                    let travel = director.travel(at: now, motionEnabled: !reduceMotion)
                    let pose = director.pose(at: now, motionEnabled: !reduceMotion)
                    let elapsed = director.elapsed(at: now)
                    let duration = director.expressionDuration(at: now)
                    let art = faceDrawingSize(in: geometry.size, portrait: portrait,
                                              emphasis: expressionEmphasis(expression, elapsed: elapsed, duration: duration))
                    let centerOffset = faceOffset(travel, in: geometry.size, art: art, portrait: portrait)
                    let glowOffset = CGSize(width: safeAreaOffset.width + centerOffset.width,
                                            height: safeAreaOffset.height + centerOffset.height)
                    ZStack {
                        screenGlow(at: now, expression: expression, variant: variant, portrait: portrait, faceOffset: glowOffset,
                                   faceScale: min(art.width / 475, art.height / 215), pose: pose)

                        PetFace(pose: pose,
                                time: now, elapsed: director.effectElapsed(at: now),
                                mouthEnabled: showMouth || director.isPlayingMarch, motionEnabled: !reduceMotion,
                                eyeTint: expressionShowActive ? nil : director.modes.eyeTint,
                                batteryLevel: isActing || isPreviewing ? nil : director.modes.batteryLevel,
                                drawingSize: art, showsBubbleDecoration: director.playSession?.activity != .bubbles,
                                centerOffset: centerOffset)
                            .allowsHitTesting(false)

                        interactionArea(expression: expression, isPreviewing: isPreviewing, isActing: isActing,
                                        pose: pose, drawingSize: art, centerOffset: centerOffset)
                        if let session = director.playSession {
                            playTargets(session, at: now, in: geometry.size)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if director.playSession == nil {
                            captions(for: expression, variant: variant, isPreviewing: isPreviewing, isPerforming: isPerforming)
                        }
                    }
                }

                VStack {
                    topControls(portrait: portrait)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                if showsConversation {
                    conversationBubble
                        .frame(maxWidth: 540)
                        .padding(.horizontal, portrait ? 20 : 112)
                        .padding(.top, portrait ? 58 : 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }

                if director.playSession != nil {
                    headerButton("退出互动", symbol: "xmark", action: director.endPlay)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(16)
                }

                if director.isPlayingMarch {
                    headerButton("停止唱歌", symbol: "stop.fill", action: director.stopMarch)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(16)
                } else if voiceAvailable && !showControls {
                    conversationControls
                        .padding(.trailing, 20)
                        .padding(.bottom, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .onChange(of: geometry.size, initial: true) { _, _ in director.updateOrientation() }
        }
        .accessibilityHidden(showControls)
        .background { PetOrientationPreference(orientation: screenOrientation) }
        .sheet(isPresented: $showControls, onDismiss: playPendingSelection) {
            controls
                .preferredColorScheme(.dark)
                .presentationDragIndicator(.visible)
        }
        .onOpenURL { url in
            guard url.absoluteString == "yuanyuan-pet://message-received" else { return }
            messageAlertID = UUID()
        }
        .task(id: messageAlertID) {
            guard messageAlertID != nil else { return }
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            messageAlertID = nil
        }
        .statusBarHidden()
        .onChange(of: settings, initial: true) { _, value in director.configure(value) }
        .onChange(of: director.senses.cameraStatus) { _, _ in director.visionCameraStatusChanged() }
        .onChange(of: wakeSettings, initial: true) { _, value in
            director.voice.configureWake(enabled: value.enabled, model: value.model,
                                         name: value.name, personality: value.personality)
        }
        .onChange(of: director.voice.phase) { _, _ in director.voicePhaseChanged() }
        .onChange(of: director.voice.isCapturingSpeech) { _, capturing in
            if !capturing && director.voice.phase == .listening { director.voicePhaseChanged() }
        }
        .onChange(of: micHeld) { _, held in if !held { endMicHold() } }
        .onChange(of: showControls) { _, showing in
            if !showing {
                activityPath.removeAll()
                director.voice.stopPreview()
                keyCheckTask?.cancel()
                keyCheckTask = nil
                checkingKey = nil
                keyInputs.removeAll()
                keyMessages.removeAll()
            }
        }
        .task {
            if petName == "桌宠" { petName = PetVoice.defaultPetName }
            installVoiceReplyHandler()
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                director.tick()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        .task(id: scenePhase == .active && proactiveGreetings) {
            guard scenePhase == .active, proactiveGreetings else { return }
            do {
                try await Task.sleep(for: .seconds(4))
                while !Task.isCancelled {
                    showGreetingIfDue()
                    try await Task.sleep(for: .seconds(5))
                }
            } catch {}
        }
        .onDisappear {
            director.voice.onReplyExpression = nil
            director.voice.onCommand = nil
            director.voice.batteryStatusReply = nil
            director.onVoiceGesture = nil
            director.voice.onMarchRequested = nil
            director.voice.configureWake(enabled: false, model: model, name: displayName, personality: selectedPersonality)
            director.stop()
        }
    }

    private func playPendingSelection() {
        guard pendingPlayActivity != nil || pendingMarch || pendingExpressionShow != nil || pendingExpression != nil else { return }
        director.configure(settings)
        if let activity = pendingPlayActivity {
            pendingPlayActivity = nil
            director.startPlay(activity)
            return
        }
        if pendingMarch {
            pendingMarch = false
            director.playMarch()
            return
        }
        if let program = pendingExpressionShow {
            pendingExpressionShow = nil
            director.startExpressionShow(program)
            return
        }
        guard let expression = pendingExpression else { return }
        pendingExpression = nil
        director.show(expression)
    }

    private var canShowGreeting: Bool {
        proactiveGreetings && scenePhase == .active && !showControls && director.canOfferGreeting
    }

    private var showsConversation: Bool {
        guard !showControls, voiceAvailable, !director.isPlayingMarch else { return false }
        return director.visionHint != nil || messageAlertID != nil || director.voice.replyText != nil || director.voice.status != nil
    }

    private var conversationBubble: some View {
        let voice = director.voice
        return PetConversationBubble(
            name: displayName,
            transcript: voice.transcript,
            message: voice.replyText ?? director.visionHint ?? (messageAlertID == nil ? nil : "你有一条新消息"),
            status: voice.status
        )
    }

    private func showGreetingIfDue() {
        guard canShowGreeting, !showsConversation else { return }
        let now = Date()
        let previous = lastGreetingAt == 0 ? nil : Date(timeIntervalSince1970: lastGreetingAt)
        guard let text = PetGreetingPeriod.greeting(at: now, after: previous) else { return }
        lastGreetingAt = now.timeIntervalSince1970
        director.prepareForVoiceInput()
        director.voice.announceGreeting(text)
    }

    @ViewBuilder
    private func topControls(portrait: Bool) -> some View {
        if let show = director.expressionShow {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("表情秀 · \(show.program.title)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(show.index + 1) / \(show.program.expressions.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("第 \(show.index + 1) 个，共 \(show.program.expressions.count) 个表情")
                }
                Spacer()
                focusStatus
                headerButton("跳过当前表情", symbol: "forward.end.fill", action: director.skipExpressionShowStep)
                headerButton("退出表情秀", symbol: "xmark", action: director.stopExpressionShow)
                if showSettingsButton {
                    headerButton("表情与设置", symbol: "slider.horizontal.3") { showControls = true }
                }
            }
        } else {
            HStack(spacing: 8) {
                if portrait {
                    Text(displayName)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer()
                if let program = director.completedExpressionShow, director.focusTimer.statusText == nil {
                    Button {
                        director.startExpressionShow(program)
                    } label: {
                        Label("再播", systemImage: "arrow.counterclockwise")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("再播\(program.title)")
                }
                focusStatus
                if showSettingsButton {
                    headerButton("表情与设置", symbol: "slider.horizontal.3") { showControls = true }
                }
            }
        }
    }

    @ViewBuilder
    private var focusStatus: some View {
        if let status = director.focusTimer.statusText {
            Label(status, systemImage: "timer")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(.ultraThinMaterial, in: Capsule())
                .layoutPriority(1)
                .allowsHitTesting(false)
        }
    }

    private func headerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.16)) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func expressionEmphasis(_ expression: PetExpression, elapsed: TimeInterval, duration: TimeInterval) -> CGFloat {
        guard expression != .idle, expression != .sleepy, mode != .nightLight || expressionShowActive else { return 1 }
        let strength: CGFloat = expression == .happy || expression == .laughing || expression == .surprised ? 0.25 : 0.17
        guard !reduceMotion else { return 1 + strength }
        let progress = CGFloat(min(1, max(0, min(elapsed / 0.24, (duration - elapsed) / 0.26))))
        return 1 + strength * progress * progress * (3 - 2 * progress)
    }

    private func faceDrawingSize(in size: CGSize, portrait: Bool, emphasis: CGFloat) -> CGSize {
        let availableWidth = max(1, size.width - (portrait ? 16 : 56))
        let heightLimit = portrait ? size.width * 0.50 : size.height * 0.80
        let width = min(availableWidth, portrait ? 460 : 650, heightLimit * 2.18) * emphasis
        return CGSize(width: width, height: width / 2.18)
    }

    private func faceOffset(_ travel: CGPoint, in size: CGSize, art: CGSize, portrait: Bool) -> CGSize {
        // Keep the eyes inside the screen and clear of the controls.
        CGSize(width: travel.x * max(0, size.width / 2 - art.width * 0.26 - 12),
               height: travel.y * max(0, size.height / 2 - art.height * 0.30 - (portrait ? 36 : 16)))
    }

    private func screenGlow(at now: TimeInterval, expression: PetExpression, variant: PetExpressionVariant, portrait: Bool,
                            faceOffset: CGSize, faceScale: CGFloat, pose: PetPose) -> some View {
        ZStack {
            if !expressionShowActive, let tint = director.modes.glowTint {
                PetScreenGlow(expression: .idle, elapsed: 0, motionEnabled: false,
                              tintOverride: tint, tintStrength: Double(director.brightness(motionEnabled: !reduceMotion)))
            } else {
                let layers = reduceMotion
                    ? [PetPlayback.GlowLayer(expression: expression, startedAt: now, opacity: 1, variant: variant)]
                    : director.glow(at: now)
                ForEach(layers.indices, id: \.self) { index in
                    let layer = layers[index]
                    PetScreenGlow(expression: layer.expression, elapsed: layer.exitElapsed ?? (now - layer.startedAt),
                                  motionEnabled: !reduceMotion, variant: layer.variant, isBaseline: layer.isBaseline,
                                  playbackDuration: layer.duration,
                                  faceOffset: faceOffset, faceScale: faceScale, pose: layer.exitPose ?? pose)
                        .opacity(layer.opacity * (layer.expression == .idle ? 0.22 : 0.62))
                }
                if portrait, !expressionShowActive, let level = director.modes.batteryLevel {
                    PetBatteryGlow(level: level)
                }
            }
        }
        .opacity(mode == .nightLight ? 1 : Double(director.brightness(motionEnabled: !reduceMotion)))
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func captions(for expression: PetExpression, variant: PetExpressionVariant,
                          isPreviewing: Bool, isPerforming: Bool) -> some View {
        VStack(spacing: 4) {
            if let status = caption(for: expression, variant: variant, isPreviewing: isPreviewing, isPerforming: isPerforming) {
                Text(status)
            }
            if let battery = director.modes.batteryCaption {
                Text(expressionShowActive ? "设备 · \(battery)" : battery)
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Color(red: 0.81, green: 0.79, blue: 0.91))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding(.horizontal, 72)
        .padding(.bottom, 16)
        .allowsHitTesting(false)
    }

    private func caption(for expression: PetExpression, variant: PetExpressionVariant,
                         isPreviewing: Bool, isPerforming: Bool) -> String? {
        if let show = director.expressionShow, expression == .idle, show.program.expressions[show.index] != .idle {
            return nil
        }
        if expressionShowActive || isPerforming {
            if expression.depictsSystemState { return "表情演绎 · \(expression.rawValue)" }
            return expressionShowActive || showPetCaption ? expression.rawValue : nil
        }
        if isPreviewing {
            let title = "预览 · \(expression.rawValue)"
            if expression.hasVariants { return "\(title) · \(variant.rawValue + 1)/\(PetExpressionVariant.allCases.count)" }
            return title
        }
        if director.isPlayingMarch { return "圆圆进行曲" }
        if let status = director.notice ?? director.countdownText() ?? director.modes.caption {
            return status
        }
        guard showPetCaption, !showsConversation else { return nil }
        if expression == .idle, director.focusTimer.isFocusing { return nil }
        if expression == .idle, director.voice.isWaitingForWake {
            return "说「嘿，\(displayName)」唤醒"
        }
        if mode == .battery && (expression == .idle || expression == .charging || expression == .charged) { return nil }
        if expression == .idle { return mode == .normal ? "轻点，换个表情" : "轻点，它会回应你" }
        return expression.rawValue
    }

    private var voiceAvailable: Bool { !expressionShowActive && mode != .nightLight && !director.senses.isFaceDown }

    private var canStopVoice: Bool {
        !director.voice.canRecord && !director.voice.isPreviewing
    }

    private var conversationControls: some View {
        HStack(spacing: 10) {
            if showsConversation && director.voice.canRecord && director.visionHint == nil {
                if director.voice.replyText != nil {
                    headerButton("重播回复", symbol: "speaker.wave.2") {
                        director.voice.replayReply()
                    }
                }
                headerButton("关闭对话气泡", symbol: "xmark") {
                    messageAlertID = nil
                    director.voice.dismissConversation()
                }
            }
            if showVoiceButton && (director.canUseVoice || micStarted) {
                microphoneControl
            }
            if !director.focusTimer.isFocusing { visionControl }
            Button(action: toggleConversation) {
                Image(systemName: canStopVoice ? "xmark" : "mic.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .frame(width: 60, height: 60)
                    .background(canStopVoice ? AnyShapeStyle(Color.red.opacity(0.28)) : AnyShapeStyle(.ultraThinMaterial),
                                in: Circle())
                    .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(canStopVoice ? "结束对话" : "开始说话")
            .disabled(!canStopVoice && !director.canUseVoice)
        }
    }

    private var visionControl: some View {
        let active = visionEnabled && director.senses.cameraStatus == .active
        let status = if !visionEnabled { "已关闭" } else {
            switch director.senses.cameraStatus {
            case .active: "前置相机已开启"
            case .denied: "相机权限未开启"
            case .unavailable: "相机暂不可用"
            case .thermal: "设备过热，已暂停"
            case .inactive: "前置相机已暂停"
            case .starting: "前置相机正在开启"
            }
        }
        return Button {
            visionEnabled.toggle()
        } label: {
            Image(systemName: active ? "eye.fill" : "eye")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(active ? Color.cyan : Color.white)
                .frame(width: 60, height: 60)
                .background(active ? AnyShapeStyle(Color.cyan.opacity(0.17)) : AnyShapeStyle(.ultraThinMaterial),
                            in: Circle())
                .overlay { Circle().strokeBorder(active ? .cyan.opacity(0.5) : .white.opacity(0.18)) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(visionEnabled ? "关闭隔空互动" : "开启隔空互动")
        .accessibilityValue(status)
    }

    private var microphoneControl: some View {
        let listening = director.voice.isCapturingSpeech
        return Image(systemName: "mic")
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(.ultraThinMaterial, in: Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
            .scaleEffect(micHeld && !reduceMotion ? 1.08 : 1)
            .opacity(listening ? 0 : 1)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($micHeld) { _, held, _ in held = true }
                    .onChanged { _ in
                        guard !micStarted else { return }
                        micStarted = true
                        beginVoice()
                    }
                    .onEnded { _ in endMicHold() }
            )
            .accessibilityLabel("按住说话")
            .accessibilityHint("轻点两次开启或结束连续对话")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggleConversation() }
    }

    private func toggleConversation() {
        if canStopVoice {
            director.voice.cancel()
        } else {
            beginVoice(pushToTalk: false)
        }
    }

    private func beginVoice(pushToTalk: Bool = true) {
        guard director.canUseVoice else { return }
        director.prepareForVoiceInput()
        let activeGreeting = director.voice.replyText.flatMap { text in
            [PetGreetingPeriod.morning.greeting, PetGreetingPeriod.lunch.greeting].contains(text) ? text : nil
        }
        director.voice.begin(model: model, name: displayName, personality: selectedPersonality,
                             greeting: activeGreeting, pushToTalk: pushToTalk)
    }

    private func endMicHold() {
        guard micStarted else { return }
        micStarted = false
        director.voice.end()
    }

    private func installVoiceReplyHandler() {
        director.onVoiceGesture = { beginVoice(pushToTalk: false) }
        let selectedMode = $mode
        let timerMinutes = $nightLightMinutes
        director.voice.batteryStatusReply = { [weak director] in director?.modes.batteryVoiceReply }
        director.voice.onMarchRequested = { [weak director] in director?.playMarch() }
        director.voice.onReplyExpression = { [weak director] in director?.playVoiceReply($0) }
        director.voice.onCommand = { [weak director] command in
            guard let director else { return }
            switch command {
            case .none: break
            case .setMode(let value):
                if let next = PetMode(rawValue: value) {
                    if next == .nightLight && selectedMode.wrappedValue == .nightLight {
                        director.modes.restartNightLight(minutes: timerMinutes.wrappedValue)
                    }
                    selectedMode.wrappedValue = next
                }
            case .nightLightTimer(let minutes):
                guard PetModes.timerOptions.contains(minutes), minutes > 0 else { return }
                if selectedMode.wrappedValue == .nightLight && timerMinutes.wrappedValue == minutes {
                    director.modes.restartNightLight(minutes: minutes)
                }
                timerMinutes.wrappedValue = minutes
                selectedMode.wrappedValue = .nightLight
            case .countdown(let seconds):
                director.scheduleCountdown(seconds: seconds)
            case .play(let activity):
                director.startPlay(activity)
            case .face(let action):
                director.playFaceAction(action)
            }
        }
    }

    private func interactionArea(expression: PetExpression, isPreviewing: Bool, isActing: Bool,
                                 pose: PetPose, drawingSize: CGSize, centerOffset: CGSize) -> some View {
        GeometryReader { geometry in
            Rectangle().fill(.clear)
                .contentShape(Rectangle())
                .accessibilityHidden(expressionShowActive)
                .gesture(
                    LongPressGesture(minimumDuration: 0.45, maximumDistance: 12)
                        .exclusively(before: SpatialTapGesture())
                        .onEnded { result in
                            switch result {
                            case .first:
                                showControls = true
                            case .second(let tap):
                                if let eye = hitEye(at: tap.location, in: geometry.size, pose: pose,
                                                    drawingSize: drawingSize, centerOffset: centerOffset) {
                                    director.pokeEye(eye)
                                    return
                                }
                                director.respondToTap(toward: touchPoint(tap.location, in: geometry.size))
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 16)
                        .updating($faceDragActive) { _, active, _ in active = true }
                        .onChanged { drag in
                            updatePetting(drag, in: geometry.size, pose: pose, drawingSize: drawingSize, centerOffset: centerOffset)
                        }
                        .onEnded { drag in
                            updatePetting(drag, in: geometry.size, pose: pose, drawingSize: drawingSize, centerOffset: centerOffset)
                            if director.isPetting {
                                director.endPetting(completed: true)
                                return
                            }
                            let distance = drag.translation
                            guard -distance.height >= 52, -distance.height >= abs(distance.width) * 1.5 else { return }
                            beginVoice(pushToTalk: false)
                        },
                    including: voiceAvailable ? .all : .none
                )
                .onChange(of: faceDragActive) { _, active in
                    guard !active else { return }
                    // Let the drag's onEnded callback apply its release pose before clearing a cancelled gesture.
                    Task { @MainActor in
                        await Task.yield()
                        if !faceDragActive { director.endPetting(completed: false) }
                    }
                }
                .accessibilityLabel(expressionAccessibilityLabel(expression, isPreviewing: isPreviewing, isActing: isActing))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { director.respondToTap() }
                .accessibilityAction(named: Text("戳左眼")) { director.pokeEye(.left) }
                .accessibilityAction(named: Text("戳右眼")) { director.pokeEye(.right) }
                .accessibilityAction(named: Text("轻抚眼睛")) { director.playFaceAction(.squint) }
                .accessibilityAction(named: Text("打开表情与设置")) { showControls = true }
                .accessibilityActions {
                    if voiceAvailable && director.canUseVoice {
                        Button("开始连续对话") { beginVoice(pushToTalk: false) }
                    }
                }
        }
    }

    private func playTargets(_ session: PetDirector.PlaySession, at now: TimeInterval, in size: CGSize) -> some View {
        let elapsed = now - session.started
        let pointer = session.activity == .bubbles && !session.completed
            ? director.visionPointer.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            : nil
        let contact = pointer.flatMap { point in
            (0..<session.targetCount).first { index in
                let travel = elapsed - Double(index) * 0.16
                guard session.hits[index] == nil, travel >= 0 else { return false }
                let center = playTargetCenter(for: .bubbles, index: index, elapsed: travel, in: size)
                return hypot(point.x - center.x, point.y - center.y) <= 28
            }
        }
        return ZStack {
            ForEach(0..<session.targetCount, id: \.self) { index in
                let highFive = session.activity == .highFive
                let delay = highFive ? 0 : Double(index) * 0.16
                if elapsed >= delay {
                    let hit = session.hits[index]
                    let center = playTargetCenter(for: session.activity, index: index, elapsed: elapsed - delay, in: size)
                    if hit == nil || now - (hit?.time ?? now) < 0.42 {
                        if let hit {
                            let progress = min(1, max(0, (now - hit.time) / 0.42))
                            let recoil = highFive && !reduceMotion ? sin(progress * .pi) * 19 : 0
                            ZStack {
                                if highFive {
                                    playPalm
                                }
                                ForEach(0..<6) { ray in
                                    let angle = Double(ray) * .pi / 3
                                    Image(systemName: highFive ? "sparkle" : "circle.fill")
                                        .font(.system(size: highFive ? 14 : 6, weight: .semibold))
                                        .foregroundStyle(highFive ? Color.yellow : Color.cyan)
                                        .offset(x: cos(angle) * (20 + progress * 28),
                                                y: sin(angle) * (20 + progress * 28))
                                }
                            }
                            .opacity(1 - progress)
                            .position(x: hit.center.x + recoil, y: hit.center.y + recoil)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        } else {
                            Button {
                                director.hitPlayTarget(index, at: center)
                            } label: {
                                if highFive {
                                    playPalm
                                } else {
                                    Circle()
                                        .fill(.cyan.opacity(0.17))
                                        .overlay {
                                            Circle().strokeBorder(
                                                LinearGradient(colors: [.white, .cyan, .purple],
                                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                                lineWidth: 2
                                            )
                                        }
                                        .overlay(alignment: .topLeading) {
                                            Capsule().fill(.white.opacity(0.8))
                                                .frame(width: 13, height: 4)
                                                .rotationEffect(.degrees(-40))
                                                .padding(9)
                                        }
                                        .frame(width: index.isMultiple(of: 2) ? 45 : 52,
                                               height: index.isMultiple(of: 2) ? 45 : 52)
                                        .frame(width: 54, height: 54)
                                        .contentShape(Circle())
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(highFive ? "拍圆圆的手掌" : "戳破第 \(index + 1) 颗泡泡")
                            .position(center)
                        }
                    }
                }
            }
            if let pointer {
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .overlay { Circle().strokeBorder(.cyan, lineWidth: 2) }
                    .shadow(color: .cyan, radius: 6)
                    .position(pointer)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size.width, height: size.height)
        .onChange(of: contact, initial: true) { _, index in
            guard let index, director.playSession?.started == session.started else { return }
            let travel = elapsed - Double(index) * 0.16
            director.hitPlayTarget(index, at: playTargetCenter(for: .bubbles, index: index, elapsed: travel, in: size))
        }
        .onChange(of: director.visionHighFivePending, initial: true) { _, pending in
            if pending && session.activity == .highFive {
                director.consumeVisionHighFive(at: playTargetCenter(for: .highFive, index: 0, elapsed: elapsed, in: size))
            }
        }
    }

    private var playPalm: some View {
        Image(systemName: "hand.raised.fill")
            .font(.system(size: 49, weight: .semibold))
            .foregroundStyle(Color(red: 1, green: 0.91, blue: 0.76))
            .frame(width: 83, height: 83)
            .background(.yellow.opacity(0.10), in: Circle())
            .overlay { Circle().strokeBorder(.yellow.opacity(0.42), lineWidth: 1.5) }
            .contentShape(Circle())
    }

    private func playTargetCenter(for activity: PetDirector.PlayActivity, index: Int, elapsed: TimeInterval,
                                  in size: CGSize) -> CGPoint {
        let time = reduceMotion ? 0.8 : elapsed
        if activity == .highFive {
            let rise = min(1, time / 0.28)
            return CGPoint(x: size.width * 0.83, y: size.height * 0.52 + (1 - rise) * 50)
        }
        let offsets: [CGFloat] = [-0.31, -0.14, 0.16, 0.32]
        let heights: [CGFloat] = [0.47, 0.68, 0.68, 0.45]
        let lift = min(1, time / 0.72)
        let drift = reduceMotion ? 0 : sin(time * 1.8 + Double(index)) * 8 * lift
        return CGPoint(x: size.width * (0.5 + offsets[index] * (0.65 + 0.35 * lift)) + drift,
                       y: size.height * (heights[index] + (1 - lift) * 0.12))
    }

    private func hitEye(at location: CGPoint, in size: CGSize, pose: PetPose,
                        drawingSize: CGSize, centerOffset: CGSize) -> PetDirector.EyeSide? {
        let scale = min(drawingSize.width / 475, drawingSize.height / 215)
        guard scale > 0, max(pose.hearts, pose.stars, pose.glasses, pose.spirals) < 0.75 else { return nil }
        let x = (location.x - size.width / 2 - centerOffset.width) / scale - pose.lookX
        let y = (location.y - size.height / 2 - centerOffset.height) / scale - pose.lookY - pose.bounce
        let angle = pose.turn * .pi / 36
        let localX = (x * cos(angle) + y * sin(angle)) / (1 - abs(pose.turn) * 0.065)
        let localY = -x * sin(angle) + y * cos(angle)
        let side: PetDirector.EyeSide = localX < 0 ? .left : .right
        let eye = side == .left ? pose.left : pose.right
        let originX: CGFloat = side == .left ? -76 : 76
        let dx = (localX - originX - eye.shift) / max(28, eye.width * 39)
        let dy = (localY - eye.lift) / max(21, eye.height * 56)
        return dx * dx + dy * dy <= 1 ? side : nil
    }

    private func updatePetting(_ drag: DragGesture.Value, in size: CGSize,
                               pose: PetPose, drawingSize: CGSize, centerOffset: CGSize) {
        let distance = drag.translation
        let isHorizontal = abs(distance.width) >= 16 && abs(distance.width) > abs(distance.height) * 1.5
        if !director.isPetting {
            guard isHorizontal else { return }
            // Sample across the stroke so it can begin beside the eyes and cross them.
            let steps = max(1, Int(ceil(abs(distance.width) / 12)))
            guard (0...steps).contains(where: { step in
                let progress = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(x: drag.startLocation.x + distance.width * progress,
                                    y: drag.startLocation.y + distance.height * progress)
                return hitEye(at: point, in: size, pose: pose, drawingSize: drawingSize, centerOffset: centerOffset) != nil
            }) else { return }
        }
        director.pet(toward: touchPoint(drag.location, in: size), distance: abs(distance.width))
    }

    private func touchPoint(_ location: CGPoint, in size: CGSize) -> CGPoint {
        let x = 2 * location.x / max(size.width, 1) - 1
        let y = 2 * location.y / max(size.height, 1) - 1
        return CGPoint(x: min(1, max(-1, x)), y: min(1, max(-1, y)))
    }

    private func expressionAccessibilityLabel(_ expression: PetExpression, isPreviewing: Bool, isActing: Bool) -> String {
        if isActing { return "\(displayName)，表情演绎，\(expression.rawValue)" }
        if isPreviewing { return "\(displayName)，表情预览，\(expression.rawValue)" }
        return "\(displayName)，\(expression.rawValue)"
    }

    private var controls: some View {
        NavigationStack(path: $activityPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    activitySettings
                    playSettings
                    modeSettings
                    expressionShowSettings
                    displaySettings
                    senseSettings
                    voiceSettings
                    voiceCommandSettings
                    voicePlaybackSettings
                    ForEach(PetExpression.groups.indices, id: \.self) { index in
                        let group = PetExpression.groups[index]
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                                ForEach(group.expressions) { expression in
                                    Button {
                                        pendingExpression = expression
                                        showControls = false
                                    } label: {
                                        Label(expression.rawValue, systemImage: expression.symbol)
                                            .font(.subheadline)
                                            .lineLimit(2)
                                            .padding(.horizontal, 5)
                                            .frame(maxWidth: .infinity, minHeight: 46)
                                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    VStack(spacing: 12) {
                        Toggle("显示嘴巴", isOn: $showMouth)
                        Toggle("屏幕常亮", isOn: $keepAwake)
                    }
                    .padding(14)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                }
                .frame(maxWidth: 650)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("表情与设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showControls = false }
                }
            }
            .background(Color(red: 0.075, green: 0.066, blue: 0.13))
            .navigationDestination(for: ActivityPage.self) { page in
                switch page {
                case .focus:
                    PetFocusPanel(timer: director.focusTimer, onPlay: { activityPath.append(.game) },
                                  onClose: { showControls = false })
                case .game:
                    PetCatchGame(onExit: { _ = activityPath.popLast() })
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
        .tint(Color(red: 0.75, green: 0.69, blue: 1))
    }

    private var activitySettings: some View {
        settingsSection("活动") {
            NavigationLink(value: ActivityPage.focus) {
                HStack {
                    Label("番茄钟", systemImage: "timer")
                    Spacer()
                    if let status = director.focusTimer.statusText {
                        Text(status)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            NavigationLink(value: ActivityPage.game) {
                HStack {
                    Label("扔球接球", systemImage: "tennisball")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    private var playSettings: some View {
        settingsSection("和圆圆玩") {
            HStack(spacing: 24) {
                ForEach([PetDirector.PlayActivity.bubbles, .highFive]) { activity in
                    Button(activity.rawValue) {
                        pendingPlayActivity = activity
                        showControls = false
                    }
                    .disabled(mode == .nightLight || director.focusTimer.isFocusing || director.senses.isFaceDown)
                }
            }
        }
    }

    private var displaySettings: some View {
        settingsSection("屏幕与按钮") {
            HStack {
                Text("屏幕方向")
                Spacer()
                Picker("屏幕方向", selection: $screenOrientation) {
                    ForEach(PetScreenOrientation.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Toggle("显示设置按钮", isOn: $showSettingsButton)
            if !showSettingsButton { settingsNote("长按桌宠，打开表情与设置。") }
            Toggle("显示按住说话按钮", isOn: $showVoiceButton)
            Toggle("显示表情和待机提示", isOn: $showPetCaption)
            Toggle("主动问候", isOn: $proactiveGreetings)
            settingsNote("早上和中午，圆圆会在主画面空闲时各问候一次。")
            settingsNote("点麦克风或向上滑开始聊天，停顿后自动发送。")
        }
    }

    private var modeSettings: some View {
        settingsSection("模式") {
            Picker("桌宠模式", selection: $mode) {
                ForEach(PetMode.allCases) { choice in Text(choice.title).tag(choice) }
            }
            .pickerStyle(.segmented)
            if mode == .normal { settingsNote("自动换表情，轻点时看向触点并播放下一个。") }
            if mode == .companion { settingsNote("安静陪伴，轻点会回应。") }
            if mode == .nightLight {
                Picker("夜灯定时", selection: $nightLightMinutes) {
                    ForEach(PetModes.timerOptions, id: \.self) { minutes in
                        Text(minutes == 0 ? "不定时" : "\(minutes) 分钟").tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                if director.modes.nightLightExpired {
                    Button("重新开启夜灯") {
                        director.modes.restartNightLight(minutes: nightLightMinutes)
                    }
                }
            }
        }
    }

    private var expressionShowSettings: some View {
        settingsSection("表情秀") {
            ForEach(PetExpressionShow.allCases) { program in
                Button {
                    pendingExpressionShow = program
                    showControls = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.circle")
                            .font(.title3)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(program.title)
                                .font(.subheadline.weight(.semibold))
                            Text("\(program.expressions.count) 个表情 · \(showDuration(program.estimatedSeconds))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func showDuration(_ seconds: Int) -> String {
        if seconds >= 60 { return "约 \(max(1, Int((Double(seconds) / 60).rounded()))) 分钟" }
        return "约 \(seconds) 秒"
    }

    private var senseSettings: some View {
        settingsSection("互动感知") {
            Toggle("眼神跟随（手和脸）", isOn: $eyeTracking)
                .onChange(of: eyeTracking) { _, enabled in
                    if enabled && mode != .nightLight { director.senses.requestCameraPermission() }
                }
            Toggle("手势互动", isOn: $handGestures)
                .onChange(of: handGestures) { _, enabled in
                    if enabled && mode != .nightLight { director.senses.requestCameraPermission() }
                }
            if handGestures {
                VStack(alignment: .leading, spacing: 6) {
                    Label("张开手掌，左右来回挥：圆圆挥手打招呼", systemImage: "hand.wave")
                    Label("五指张开再收拢：开始语音对话", systemImage: "hand.raised")
                    Label("双手食指尖和拇指尖相碰，围成心形", systemImage: "heart")
                    Label("收起四指，竖起大拇指", systemImage: "hand.thumbsup")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if director.focusTimer.isFocusing {
                    settingsNote("专注计时期间会暂停手势互动。")
                } else if mode != .nightLight {
                    settingsNote("回到主画面就能试一试。")
                }
            }
            settingsNote("点主画面右下角的眼睛开启隔空互动。伸出食指可戳泡泡，举掌停稳后向前推可击掌。")
            if visionEnabled || eyeTracking || handGestures {
                switch director.senses.cameraStatus {
                case .denied: permissionLink("相机权限未开启")
                case .unavailable: settingsNote("当前设备无法使用前置相机。")
                default: EmptyView()
                }
            }
            Toggle("体感", isOn: $motion)
            if motion && director.senses.motionUnavailable { settingsNote("当前设备无法使用运动传感器。") }
            Toggle("声音反应", isOn: $sound)
                .onChange(of: sound) { _, enabled in
                    if enabled && mode != .nightLight { director.audio.requestAmbientPermission() }
                }
            if sound && director.audio.microphoneDenied { permissionLink("麦克风权限未开启") }
            if mode == .nightLight { settingsNote("夜灯模式会暂停相机和麦克风。") }
        }
    }

    private var voiceSettings: some View {
        settingsSection("语音对话") {
            apiKeySettings(.deepSeek, configured: director.voice.hasDeepSeekKey,
                           detail: "生成聊天回复。自由聊天会发送转写文字和近期对话。")
            TextField("模型名称", text: $model, prompt: Text(DeepSeekClient.defaultModel))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .disabled(checkingKey == .deepSeek)
            TextField("宠物名字", text: $petName)
                .textFieldStyle(.roundedBorder)
            Picker("性格", selection: $personality) {
                ForEach(["黏人", "傲娇", "元气", "自定义"], id: \.self) { choice in Text(choice) }
            }
            .pickerStyle(.segmented)
            if personality == "自定义" {
                TextField("用一句话描述它的性格", text: $customPersonality)
                    .textFieldStyle(.roundedBorder)
            }
            Divider()
            apiKeySettings(.doubao, configured: director.voice.hasDoubaoKey,
                           detail: "负责实时转写和团子音色播报。未配置时使用 iPhone 本机语音。")
            settingsNote("验证会发送一小段静音和固定试听文本。主动录音和云端播报由火山引擎处理。")
            Link("打开豆包语音 API Key 管理",
                 destination: URL(string: "https://console.volcengine.com/speech/new/setting/apikeys?projectName=default")!)
                .font(.footnote)
            if director.audio.microphoneDenied { permissionLink("麦克风权限未开启") }
            if director.voice.speechPermissionDenied && (!director.voice.hasDoubaoKey || voiceWakeEnabled) {
                permissionLink("本机语音识别权限未开启")
            }
        }
    }

    private func apiKeySettings(_ account: KeychainStore.Account, configured: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(account.serviceName).font(.subheadline.weight(.semibold))
                Spacer()
                settingsNote(configured ? "已保存" : "未配置")
            }
            settingsNote(detail)
            let input = Binding(get: { keyInputs[account, default: ""] },
                                set: { keyInputs[account] = $0 })
            SecureField(configured ? "输入新 Key 替换" : "\(account.serviceName) API Key", text: input)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .privacySensitive()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(account.serviceName) API Key")
                .disabled(checkingKey != nil)
            HStack {
                Button("验证并保存") { checkKey(account, replacement: input.wrappedValue) }
                    .disabled(input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if configured {
                    Button("测试连接") { checkKey(account) }
                    Spacer()
                    Button("移除 Key", role: .destructive) { removeKey(account) }
                }
            }
            .disabled(checkingKey != nil)
            if let message = keyMessages[account] { settingsNote(message) }
        }
    }

    private var voicePlaybackSettings: some View {
        settingsSection("播报音色") {
            settingsNote(director.voice.hasDoubaoKey ? "豆包语音 · 团子音色" : "内置普通话女声 · 离线播报")
            if let status = director.voice.voiceOutputNotice { settingsNote(status) }
            Button(director.voice.isPreviewing ? "停止试听" : "试听当前音色") {
                if director.voice.isPreviewing {
                    director.voice.stopPreview()
                } else {
                    director.prepareForVoiceInput()
                    director.voice.previewVoice()
                }
            }
            .font(.footnote)
        }
    }

    private var voiceCommandSettings: some View {
        settingsSection("语音唤醒与表情音效") {
            Toggle("喊名字唤醒", isOn: $voiceWakeEnabled)
            settingsNote("开启后，麦克风只在主画面用本机识别名字。说「嘿，\(displayName)」，停一下再说指令。")
            Toggle("表情音效", isOn: $expressionSounds)
                .onChange(of: expressionSounds) { _, _ in expressionSoundPreviewFailed = false }
            settingsNote("开启后，35 个表情各有短音效。静音模式下也会播放，音量跟随 iPhone 的媒体音量。")
            Button("试听表情音效") {
                director.configure(settings)
                expressionSoundPreviewFailed = !director.previewExpressionSound()
            }
            .font(.footnote)
            .disabled(!expressionSounds)
            if expressionSounds && expressionSoundPreviewFailed {
                settingsNote("暂时无法播放，请稍后再试。")
            }
            settingsNote("「给我唱首歌」或「唱圆圆进行曲」可播放固定歌曲。也可以说「跳个舞」「比个心」「吹泡泡」。")
            if mode != .nightLight {
                Button("试听圆圆进行曲") {
                    pendingMarch = true
                    showControls = false
                }
                .disabled(director.senses.isFaceDown)
            }
            if let notice = director.voice.wakeNotice { settingsNote(notice) }
            if let transcript = director.voice.lastTranscript, !transcript.isEmpty {
                settingsNote("上次听到：\(transcript)")
            }
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }

    private func permissionLink(_ text: String) -> some View {
        HStack {
            settingsNote(text)
            Spacer()
            Button("打开系统设置") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .font(.footnote)
        }
    }

    private func settingsNote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func checkKey(_ account: KeychainStore.Account, replacement: String? = nil) {
        guard checkingKey == nil else { return }
        checkingKey = account
        keyMessages[account] = "正在验证\(account.serviceName)…"
        let selectedModel = model
        keyCheckTask = Task {
            do {
                try await director.voice.checkAPIKey(account: account, replacement: replacement, model: selectedModel)
                guard !Task.isCancelled else { return }
                if replacement != nil { keyInputs[account] = nil }
                keyMessages[account] = replacement == nil ? "连接正常。" : "验证通过，Key 已保存到本机钥匙串。"
            } catch {
                guard !Task.isCancelled else { return }
                keyMessages[account] = Self.keyCheckMessage(for: error)
            }
            checkingKey = nil
            keyCheckTask = nil
        }
    }

    private static func keyCheckMessage(for error: Error) -> String {
        switch error {
        case PetVoice.KeyCheckError.missingKey: "请先填写 API Key。"
        case let PetVoice.KeyCheckError.doubaoCheckFailed(feature, error):
            switch error {
            case DoubaoVoiceClient.VoiceError.serviceCode(let code):
                "豆包\(feature)验证失败（\(code)）。请检查当前项目的服务权限和 Key。"
            case let networkError as URLError where [.notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost].contains(networkError.code):
                "豆包\(feature)连接失败，请检查网络后重试。"
            default:
                "豆包\(feature)验证失败，请检查 Key、服务开通状态和网络。"
            }
        case DeepSeekClient.RequestError.httpStatus(401): "DeepSeek 拒绝了这把 Key（401）。请检查完整密钥。"
        case DeepSeekClient.RequestError.httpStatus(402): "DeepSeek 余额不足（402）。"
        case DeepSeekClient.RequestError.httpStatus(429): "DeepSeek 请求过多（429），请稍后重试。"
        case DeepSeekClient.RequestError.httpStatus(let code): "DeepSeek 返回错误（\(code)）。请检查模型名称或稍后重试。"
        case DeepSeekClient.RequestError.invalidResponse: "DeepSeek 的回复格式有误，请重试。"
        case is KeychainStore.KeychainError: "无法访问钥匙串，请解锁 iPhone 后重试。"
        case is URLError: "连接失败，请检查网络后重试。"
        default: "验证失败，请重试。"
        }
    }

    private func removeKey(_ account: KeychainStore.Account) {
        do {
            try director.voice.removeAPIKey(account: account)
            keyInputs[account] = nil
            keyMessages[account] = account == .doubao ? "Key 已移除，已切回本机语音。" : "Key 已移除。"
        } catch {
            keyMessages[account] = Self.keyCheckMessage(for: error)
        }
    }
}
