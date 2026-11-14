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
    @State private var activityPath: [ActivityPage] = []
    @State private var pendingExpression: PetExpression?
    @State private var pendingExpressionShow: PetExpressionShow?
    @State private var pendingMarch = false
    @State private var expressionSoundPreviewFailed = false
    @State private var keyInput = ""
    @State private var keyMessage: String?
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
                             eyeTracking: eyeTracking, handGestures: handGestures, motion: motion, sound: sound,
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
                                drawingSize: art, centerOffset: centerOffset)
                            .allowsHitTesting(false)

                        interactionArea(expression: expression, isPreviewing: isPreviewing, isActing: isActing)
                    }
                    .overlay(alignment: .bottom) {
                        captions(for: expression, variant: variant, isPreviewing: isPreviewing, isPerforming: isPerforming)
                    }
                }

                VStack {
                    topControls(portrait: portrait)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                if director.isPlayingMarch {
                    headerButton("停止唱歌", symbol: "stop.fill", action: director.stopMarch)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(16)
                } else if voiceAvailable && showVoiceButton && (!director.voice.isCapturingSpeech || micStarted) {
                    microphoneControl
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, 20)
                        .padding(.bottom, 10)
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
        .statusBarHidden()
        .onChange(of: settings, initial: true) { _, value in director.configure(value) }
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
                keyInput = ""
                keyMessage = nil
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
        .onDisappear {
            director.voice.onReply = nil
            director.voice.batteryStatusReply = nil
            director.voice.onMarchRequested = nil
            director.voice.configureWake(enabled: false, model: model, name: displayName, personality: selectedPersonality)
            director.stop()
        }
    }

    private func playPendingSelection() {
        guard pendingMarch || pendingExpressionShow != nil || pendingExpression != nil else { return }
        director.configure(settings)
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
        // Reserve space for both eyes and leave the controls and subtitle readable at the edges.
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

    private var voiceStatus: String? {
        if let caption = director.voice.caption { return caption }
        switch director.voice.phase {
        case .authorizing: return "正在准备语音"
        case .listening: return nil
        case .thinking: return "正在想怎么回复…"
        case .idle, .speaking: return nil
        }
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
        if let status = voiceStatus ?? director.notice ?? director.countdownText() ?? director.modes.caption {
            return status
        }
        guard showPetCaption else { return nil }
        if expression == .idle, director.focusTimer.isFocusing { return nil }
        if expression == .idle, director.voice.isWaitingForWake {
            return "说「嘿，\(displayName)」唤醒"
        }
        if mode == .battery && (expression == .idle || expression == .charging || expression == .charged) { return nil }
        if expression == .idle { return mode == .normal ? "轻点，换个表情" : "轻点，它会回应你" }
        return expression.rawValue
    }

    private var voiceAvailable: Bool { !expressionShowActive && mode != .nightLight && !director.senses.isFaceDown }

    private var canEndVoice: Bool {
        director.voice.phase == .listening || director.voice.phase == .authorizing
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
            .accessibilityLabel(canEndVoice ? "发送语音" : "按住说话")
            .accessibilityHint("轻点两次开始说话，再轻点两次发送")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggleVoice() }
    }

    private func toggleVoice() {
        if canEndVoice {
            director.voice.end()
        } else {
            beginVoice(pushToTalk: false)
        }
    }

    private func beginVoice(pushToTalk: Bool = true) {
        guard director.canUseVoice else { return }
        director.prepareForVoiceInput()
        director.voice.begin(model: model, name: displayName, personality: selectedPersonality, pushToTalk: pushToTalk)
    }

    private func endMicHold() {
        guard micStarted else { return }
        micStarted = false
        director.voice.end()
    }

    private func installVoiceReplyHandler() {
        let selectedMode = $mode
        let timerMinutes = $nightLightMinutes
        director.voice.batteryStatusReply = { [weak director] in director?.modes.batteryVoiceReply }
        director.voice.onMarchRequested = { [weak director] in director?.playMarch() }
        director.voice.onReply = { [weak director] expression, command in
            guard let director else { return }
            director.playVoiceReply(expression)
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
            }
        }
    }

    private func interactionArea(expression: PetExpression, isPreviewing: Bool, isActing: Bool) -> some View {
        GeometryReader { geometry in
            Rectangle().fill(.clear)
                .contentShape(Rectangle())
                .accessibilityHidden(expressionShowActive)
                .gesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .exclusively(before: SpatialTapGesture())
                        .onEnded { result in
                            switch result {
                            case .first:
                                showControls = true
                            case .second(let tap):
                                let x = 2 * tap.location.x / max(geometry.size.width, 1) - 1
                                let y = 2 * tap.location.y / max(geometry.size.height, 1) - 1
                                director.respondToTap(toward: CGPoint(x: min(1, max(-1, x)), y: min(1, max(-1, y))))
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { drag in
                            let distance = drag.translation
                            guard -distance.height >= 52, -distance.height >= abs(distance.width) * 1.5 else { return }
                            toggleVoice()
                        },
                    including: voiceAvailable ? .all : .none
                )
                .accessibilityLabel(expressionAccessibilityLabel(expression, isPreviewing: isPreviewing, isActing: isActing))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { director.respondToTap() }
                .accessibilityAction(named: Text("打开表情与设置")) { showControls = true }
                .accessibilityActions {
                    if voiceAvailable && (!showVoiceButton || director.voice.isCapturingSpeech) {
                        Button(canEndVoice ? "发送语音" : "开始说话", action: toggleVoice)
                    }
                }
        }
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
            Toggle("显示语音按钮", isOn: $showVoiceButton)
            settingsNote("在桌宠画面向上滑开始说话，再向上滑一次发送。")
            Toggle("显示表情和待机提示", isOn: $showPetCaption)
        }
    }

    private var modeSettings: some View {
        settingsSection("模式") {
            Picker("桌宠模式", selection: $mode) {
                ForEach(PetMode.allCases) { choice in Text(choice.title).tag(choice) }
            }
            .pickerStyle(.segmented)
            if mode == .normal { settingsNote("自动换表情，轻点播放下一个。") }
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
                    Label("张开手掌，左右来回挥", systemImage: "hand.wave")
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
            if eyeTracking || handGestures {
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
        settingsSection("语音聊天") {
            SecureField(director.voice.hasAPIKey ? "输入新 Key 替换" : "DeepSeek API Key", text: $keyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("DeepSeek API Key")
            HStack {
                Button("保存 Key") { saveKey() }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if director.voice.hasAPIKey {
                    Spacer()
                    Button("移除 Key", role: .destructive) { removeKey() }
                }
            }
            if let keyMessage { settingsNote(keyMessage) }
            if director.voice.hasAPIKey {
                settingsNote("已保存至 iPhone 钥匙串。聊天会将识别出的文字及近期对话发给 DeepSeek。")
            } else {
                settingsNote("填写 Key 可自由聊天。你也可以直接说「跳个舞」「回窝睡觉」「开夜灯」。")
            }
            TextField("模型名称", text: $model, prompt: Text(DeepSeekClient.defaultModel))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
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
            if director.audio.microphoneDenied { permissionLink("麦克风权限未开启") }
            if director.voice.speechPermissionDenied { permissionLink("语音识别权限未开启") }
        }
    }

    private var voicePlaybackSettings: some View {
        settingsSection("播报音色") {
            settingsNote("内置普通话女声 · 离线播报")
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

    private func saveKey() {
        do {
            try director.voice.saveAPIKey(keyInput)
            keyInput = ""
            keyMessage = "Key 已保存。"
        } catch {
            keyMessage = "保存失败，请解锁 iPhone 后重试。"
        }
    }

    private func removeKey() {
        do {
            try director.voice.removeAPIKey()
            keyInput = ""
            keyMessage = "Key 已移除。"
        } catch {
            keyMessage = "移除失败，请重试。"
        }
    }
}
