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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var systemPresence = PetSystemPresence.shared
    @AppStorage(PetSystemPresence.bannerPreference) private var messageBanners = true
    @AppStorage(PetSystemPresence.companionPreference) private var liveCompanion = true
    @AppStorage("pet.proactiveGreetings") private var proactiveGreetings = true
    @AppStorage("pet.lastGreetingAt") private var lastGreetingAt: Double = 0
    @AppStorage("pet.keepAwake") private var keepAwake = false
    @AppStorage("pet.lightweightDisplay") private var lightweightDisplay = false
    @AppStorage("pet.showMouth") private var showMouth = false
    @AppStorage("pet.mode") private var mode: PetMode = .normal
    @AppStorage("pet.nightLightMinutes") private var nightLightMinutes = 0
    @AppStorage("pet.motion") private var motion = false
    @AppStorage("pet.soundReactions") private var sound = false
    @AppStorage("pet.expressionSounds") private var expressionSounds = false
    @AppStorage("pet.voiceWakeEnabled") private var voiceWakeEnabled = false
    @AppStorage("pet.deepSeekModel") private var model = DeepSeekClient.defaultModel
    @AppStorage("pet.name") private var petName = PetVoice.defaultPetName
    @AppStorage("pet.personality") private var personality = "元气"
    @AppStorage("pet.customPersonality") private var customPersonality = ""
    @State private var director = PetDirector()
    @State private var activePanel: HomePanel?
    @State private var homeButtonsVisible = true
    @State private var homeButtonsTimer = UUID()
    @State private var touchingPet = false
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    @AppStorage("pet.hasSeenControlsHint") private var hasSeenControlsHint = false
    @State private var showControlsHint = false
    @State private var visionEnabled = false
    @State private var showCameraPermissionAlert = false
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
    @State private var expressionCategory = 0
    @State private var gestureOffset = CGSize.zero
    @AppStorage("pet.triedExpressionSwipe") private var triedExpressionSwipe = false

    private enum HomePanel: String, Identifiable {
        case play, settings

        var id: Self { self }
    }

    private enum ActivityPage: Hashable {
        case focus, game, expressionPrograms, gestures, morePlay
        case petProfile, audio, services, systemPresence
    }

    private var showControls: Bool { activePanel != nil }

    private var displayName: String {
        let name = petName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? PetVoice.defaultPetName : name
    }

    private var settings: PetDirector.Settings {
        PetDirector.Settings(mode: mode, nightLightMinutes: nightLightMinutes, keepAwake: keepAwake,
                             visionEnabled: visionEnabled, motion: motion, sound: sound,
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

    private var showsHomeButtons: Bool { homeButtonsVisible || voiceOverEnabled }

    private var expressionShowActive: Bool { director.expressionShow != nil }

    private var usesLightweightDisplay: Bool {
        lightweightDisplay || lowPowerMode || thermalState == .serious || thermalState == .critical
    }

    private var faceFrameInterval: TimeInterval {
        let interactive = touchingPet || visionEnabled || motion || director.playSession != nil
        let animated = director.isAnimatingExpression || expressionShowActive || director.isPlayingMarch
            || director.voice.phase == .speaking
        if interactive || animated {
            return usesLightweightDisplay || reduceMotion ? 1.0 / 30 : 1.0 / 60
        }
        return usesLightweightDisplay || reduceMotion ? 1.0 / 12 : 1.0 / 30
    }

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

                TimelineView(.animation(minimumInterval: faceFrameInterval, paused: scenePhase != .active || showControls)) { _ in
                    let now = director.now
                    let expression = director.expression(at: now)
                    let variant = director.expressionVariant(at: now)
                    let isPreviewing = director.isPreviewingExpression(at: now)
                    let isPerforming = director.isPerformingExpression(at: now)
                    let isActing = isPerforming || expressionShowActive
                    let travel = director.travel(at: now, motionEnabled: !reduceMotion)
                    let pose = director.pose(at: now, motionEnabled: !reduceMotion)
                    let art = faceDrawingSize(in: geometry.size, portrait: portrait,
                                              emphasis: director.faceScale(at: now, motionEnabled: !reduceMotion))
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
                                centerOffset: centerOffset, tapBurstAge: director.tapBurstAge(at: now))
                            .offset(gestureOffset)
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
                    topControls
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

                if showsHomeButtons && !showControls && !expressionShowActive && !director.isPlayingMarch
                    && director.playSession == nil && !canStopVoice {
                    cornerButton("设置", symbol: "gearshape") { activePanel = .settings }
                        .padding(.trailing, 20)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                if director.playSession != nil {
                    cornerButton("退出互动", symbol: "xmark", action: director.endPlay)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(16)
                }

                if director.isPlayingMarch {
                    cornerButton("停止唱歌", symbol: "stop.fill", action: director.stopMarch)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(16)
                } else if !expressionShowActive && !showControls {
                    HStack(spacing: 10) {
                        if director.playSession == nil {
                            if mode == .nightLight {
                                cornerButton("回到陪伴", symbol: "moon.zzz") { mode = .companion }
                            } else if voiceAvailable {
                                conversationControls
                            }
                        }
                        if voiceAvailable && (visionEnabled || (showsHomeButtons && director.playSession == nil && !director.focusTimer.isFocusing)) {
                            visionControl
                        }
                        if showsHomeButtons && director.playSession == nil && !canStopVoice {
                            cornerButton("玩法", symbol: "sparkles") { activePanel = .play }
                        }
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }

            }
            .onChange(of: geometry.size, initial: true) { _, _ in director.updateOrientation() }
        }
        .accessibilityHidden(showControls)
        .sheet(item: $activePanel, onDismiss: playPendingSelection) { panel in
            controls(panel)
                .preferredColorScheme(.dark)
                .presentationDragIndicator(.visible)
                .presentationDetents([.large])
        }
        .onOpenURL { url in
            if url == PetSystemPresence.legacyMessageURL {
                Task { await previewMessageReminder() }
            } else if url == PetLiveActivityAttributes.openURL {
                activePanel = nil
                Task { await systemPresence.openCompanion() }
            }
        }
        .onChange(of: systemPresence.messageEvent, initial: true) { _, event in
            guard let event, abs(event.timeIntervalSinceNow) < 8 else { return }
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
        .onChange(of: settings, initial: true) { _, value in
            director.configure(value)
            if !director.canBrowseExpressions { settleGesture() }
        }
        .onChange(of: director.senses.cameraStatus) { _, status in
            director.visionCameraStatusChanged()
            if visionEnabled && status == .denied {
                visionEnabled = false
                showCameraPermissionAlert = true
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .background {
                visionEnabled = false
                Task { await LocalTTSClient.releaseCachedVoice() }
            }
            if phase == .active {
                lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                thermalState = ProcessInfo.processInfo.thermalState
                revealHomeButtons()
                Task {
                    await systemPresence.syncCompanion(enabled: liveCompanion, name: displayName)
                    await systemPresence.requestBannerPermissionIfNeeded()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await LocalTTSClient.releaseCachedVoice() }
        }
        .onChange(of: mode) { _, value in
            if value == .nightLight { visionEnabled = false }
        }
        .onChange(of: director.focusTimer.isFocusing) { _, focusing in
            if focusing { visionEnabled = false }
        }
        .alert("隔空互动需要相机", isPresented: $showCameraPermissionAlert) {
            Button("打开设置") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("允许圆圆使用相机后，回来点眼睛即可开始。画面只在这台 iPhone 上处理。")
        }
        .onChange(of: wakeSettings, initial: true) { _, value in
            director.voice.configureWake(enabled: value.enabled, model: value.model,
                                         name: value.name, personality: value.personality)
        }
        .onChange(of: director.voice.phase) { _, _ in director.voicePhaseChanged() }
        .onChange(of: director.voice.isCapturingSpeech) { _, capturing in
            if !capturing && director.voice.phase == .listening { director.voicePhaseChanged() }
        }
        .onChange(of: showControls) { _, showing in
            if !showing {
                revealHomeButtons()
                activityPath.removeAll()
                director.voice.stopPreview()
                clearKeyEditing()
            }
        }
        .task(id: homeButtonsTimer) {
            guard homeButtonsVisible, !showControls, !touchingPet, scenePhase == .active, !voiceOverEnabled else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !showControls, !touchingPet, scenePhase == .active, !voiceOverEnabled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { homeButtonsVisible = false }
            guard !hasSeenControlsHint, mode != .nightLight, !expressionShowActive,
                  director.playSession == nil, !director.isPlayingMarch, !canStopVoice, !visionEnabled else { return }
            hasSeenControlsHint = true
            showControlsHint = true
            do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
            showControlsHint = false
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
        guard !showControls else { return false }
        if messageAlertID != nil { return true }
        guard voiceAvailable, !director.isPlayingMarch else { return false }
        return director.visionHint != nil || director.voice.replyText != nil || director.voice.status != nil
    }

    private var conversationBubble: some View {
        let voice = director.voice
        return PetConversationBubble(
            name: displayName,
            transcript: voice.transcript,
            message: messageAlertID == nil ? (voice.replyText ?? director.visionHint) : systemPresence.messageText,
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
    private var topControls: some View {
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
                cornerButton("跳过当前表情", symbol: "forward.end.fill", action: director.skipExpressionShowStep)
                cornerButton("退出表情秀", symbol: "xmark", action: director.stopExpressionShow)
            }
        } else {
            HStack(spacing: 8) {
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
            }
            .padding(.trailing, showsHomeButtons && director.playSession == nil && !director.isPlayingMarch && !canStopVoice ? 92 : 0)
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
                              tintOverride: tint, tintStrength: Double(pose.brightness),
                              showsHalo: !usesLightweightDisplay)
            } else {
                let layers = reduceMotion
                    ? [PetPlayback.GlowLayer(expression: expression, startedAt: now, opacity: 1, variant: variant)]
                    : director.glow(at: now)
                ForEach(layers.indices, id: \.self) { index in
                    let layer = layers[index]
                    let resting = layer.expression == .idle && layer.isBaseline
                    if layer.opacity > 0.005 {
                        PetScreenGlow(expression: layer.expression, elapsed: layer.exitElapsed ?? (now - layer.startedAt),
                                      motionEnabled: !reduceMotion, variant: layer.variant, isBaseline: layer.isBaseline,
                                      playbackDuration: layer.duration,
                                      faceOffset: faceOffset, faceScale: faceScale, pose: layer.exitPose ?? pose,
                                      showsHalo: !usesLightweightDisplay && !resting)
                            .opacity(layer.opacity * (layer.expression == .idle ? 0.22 : 0.62))
                    }
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
            if showControlsHint && !showsConversation {
                Text("轻点屏幕显示按钮")
            } else if let status = caption(for: expression, variant: variant, isPreviewing: isPreviewing, isPerforming: isPerforming) {
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
        .padding(.horizontal, 112)
        .padding(.bottom, 26)
        .allowsHitTesting(false)
    }

    private func caption(for expression: PetExpression, variant: PetExpressionVariant,
                         isPreviewing: Bool, isPerforming: Bool) -> String? {
        if let show = director.expressionShow, expression == .idle, show.program.expressions[show.index] != .idle {
            return nil
        }
        if expressionShowActive || isPerforming {
            if expression.depictsSystemState { return "表情演绎 · \(expression.rawValue)" }
            return expression.rawValue
        }
        if director.tapBurstAge(at: director.now) != nil { return "圆圆气炸啦！" }
        if director.isBrowsingExpression(at: director.now) {
            return "表情 · \(expression.rawValue)"
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
        guard !showsConversation, !director.focusTimer.isFocusing,
              expression == .idle, mode == .normal || mode == .companion else { return nil }
        if visionEnabled && director.senses.cameraStatus == .active { return "隔空互动中 · 试试挥手" }
        if director.voice.isWaitingForWake { return "说「嘿，\(displayName)」也能聊聊" }
        return triedExpressionSwipe ? "戳一戳 · 摸摸脸" : "戳一戳 · 双指滑换表情"
    }

    private var voiceAvailable: Bool { !expressionShowActive && mode != .nightLight && !director.senses.isFaceDown }

    private var canStopVoice: Bool {
        !director.voice.canRecord && !director.voice.isPreviewing
    }

    private var conversationControls: some View {
        HStack(spacing: 10) {
            if showsHomeButtons && showsConversation && director.voice.canRecord && director.visionHint == nil {
                if director.voice.replyText != nil {
                    cornerButton("重播回复", symbol: "speaker.wave.2") {
                        director.voice.replayReply()
                    }
                }
                cornerButton("收起对话", symbol: "xmark") {
                    messageAlertID = nil
                    director.voice.dismissConversation()
                }
            }
            if showsHomeButtons || canStopVoice {
                cornerButton(canStopVoice ? "结束对话" : "聊聊", symbol: canStopVoice ? "xmark" : "mic.fill",
                             highlighted: canStopVoice, action: toggleConversation)
                    .accessibilityLabel(canStopVoice ? "结束对话" : "和\(displayName)聊聊")
                    .disabled(!canStopVoice && !director.canUseVoice)
            }
        }
    }

    private var visionControl: some View {
        let status = director.senses.cameraStatus
        let active = visionEnabled && status == .active
        let title = visionEnabled ? "关闭隔空" : "隔空互动"
        let symbol: String
        let state: String
        if !visionEnabled {
            symbol = "eye"
            state = "已关闭"
        } else {
            switch status {
            case .active:
                symbol = "eye.fill"
                state = "相机已开启"
            case .starting:
                symbol = "eye"
                state = "正在开启相机"
            case .unavailable:
                symbol = "eye.slash"
                state = "相机不可用"
            default:
                symbol = "eye.slash"
                state = "相机已暂停"
            }
        }

        return Button {
            revealHomeButtons()
            visionEnabled.toggle()
        } label: {
            HStack(spacing: 6) {
                if visionEnabled && status == .starting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: symbol)
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(active ? Color.cyan : Color.white)
            .padding(.horizontal, 13)
            .frame(minHeight: 44)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(active ? Color.cyan.opacity(0.65) : .white.opacity(0.16)) }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(visionEnabled ? "关闭隔空互动" : "开启隔空互动")
        .accessibilityValue(state)
        .accessibilityHint(visionEnabled ? "" : "使用前置相机识别手势")
    }

    private func cornerButton(_ title: String, symbol: String, highlighted: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 13)
                .frame(minHeight: 44)
                .background(.ultraThinMaterial, in: Capsule())
                .background(highlighted ? Color.red.opacity(0.3) : .clear, in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.16)) }
        }
        .buttonStyle(.plain)
    }

    private func revealHomeButtons() {
        showControlsHint = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { homeButtonsVisible = true }
        homeButtonsTimer = UUID()
    }

    private func toggleConversation() {
        revealHomeButtons()
        if canStopVoice {
            director.voice.cancel()
        } else {
            beginVoice()
        }
    }

    private func beginVoice() {
        guard director.canUseVoice else { return }
        director.prepareForVoiceInput()
        let activeGreeting = director.voice.replyText.flatMap { text in
            [PetGreetingPeriod.morning.greeting, PetGreetingPeriod.lunch.greeting].contains(text) ? text : nil
        }
        director.voice.begin(model: model, name: displayName, personality: selectedPersonality,
                             greeting: activeGreeting, pushToTalk: false)
    }

    private func installVoiceReplyHandler() {
        director.onVoiceGesture = { beginVoice() }
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
            PetTouchSurface { event in
                switch event {
                case .contact(let active):
                    touchingPet = active
                    revealHomeButtons()
                case .tap(let location):
                    let size = geometry.size
                    if let point = facePoint(at: location, in: size, pose: pose,
                                             drawingSize: drawingSize, centerOffset: centerOffset) {
                        let eye = hitEye(at: point, pose: pose)
                        if eye != nil || (abs(point.x) <= 140 && abs(point.y) <= 78) {
                            director.respondToTap(toward: touchPoint(location, in: size), eye: eye)
                            return
                        }
                    }
                    if director.browseExpressions(1) {
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                case .longPress:
                    if !canStopVoice { activePanel = .play }
                case .stroke(let start, let location):
                    updatePetting(from: start, to: location, in: geometry.size,
                                  pose: pose, drawingSize: drawingSize, centerOffset: centerOffset)
                case .strokeEnded(let upward):
                    if director.isPetting {
                        director.endPetting(completed: true)
                    } else if upward {
                        beginVoice()
                    }
                case .cancelled:
                    director.endPetting(completed: false)
                    settleGesture()
                case .tracking(let offset):
                    if director.canBrowseExpressions && !reduceMotion { gestureOffset = offset }
                case .browse(let step):
                    settleGesture()
                    browseExpressions(step)
                case .celebrate:
                    settleGesture()
                    if director.celebrateSwipe() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                }
            }
                .accessibilityElement(children: .ignore)
                .accessibilityHidden(expressionShowActive)
                .accessibilityLabel(expressionAccessibilityLabel(expression, isPreviewing: isPreviewing, isActing: isActing))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    revealHomeButtons()
                    director.respondToTap()
                }
                .accessibilityAction(named: Text("戳左眼")) { director.respondToTap(eye: .left) }
                .accessibilityAction(named: Text("戳右眼")) { director.respondToTap(eye: .right) }
                .accessibilityAction(named: Text("轻抚眼睛")) { director.playFaceAction(.squint) }
                .accessibilityAction(named: Text("打开玩法")) { activePanel = .play }
                .accessibilityAction(named: Text("打开设置")) { activePanel = .settings }
                .accessibilityActions {
                    if voiceAvailable && director.canUseVoice {
                        Button("开始连续对话") { beginVoice() }
                    }
                    if director.canBrowseExpressions {
                        Button("下一个常用表情") { browseExpressions(1) }
                        Button("上一个常用表情") { browseExpressions(-1) }
                        Button("放彩带") { _ = director.celebrateSwipe() }
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

    private func facePoint(at location: CGPoint, in size: CGSize, pose: PetPose,
                           drawingSize: CGSize, centerOffset: CGSize) -> CGPoint? {
        let scale = min(drawingSize.width / 475, drawingSize.height / 215)
        guard scale > 0 else { return nil }
        let x = (location.x - size.width / 2 - centerOffset.width - gestureOffset.width) / scale - pose.lookX
        let y = (location.y - size.height / 2 - centerOffset.height - gestureOffset.height) / scale - pose.lookY - pose.bounce
        let angle = pose.turn * .pi / 36
        return CGPoint(x: (x * cos(angle) + y * sin(angle)) / (1 - abs(pose.turn) * 0.065),
                       y: -x * sin(angle) + y * cos(angle))
    }

    private func hitEye(at point: CGPoint, pose: PetPose) -> PetDirector.EyeSide? {
        guard max(pose.hearts, pose.stars, pose.glasses, pose.spirals) < 0.75 else { return nil }
        let localX = point.x
        let localY = point.y
        let side: PetDirector.EyeSide = localX < 0 ? .left : .right
        let eye = side == .left ? pose.left : pose.right
        let originX: CGFloat = side == .left ? -76 : 76
        let dx = (localX - originX - eye.shift) / max(28, eye.width * 39)
        let dy = (localY - eye.lift) / max(21, eye.height * 56)
        return dx * dx + dy * dy <= 1 ? side : nil
    }

    private func browseExpressions(_ step: Int) {
        guard director.browseExpressions(step) else { return }
        triedExpressionSwipe = true
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func settleGesture() {
        guard gestureOffset != .zero else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.90)) {
            gestureOffset = .zero
        }
    }

    private func updatePetting(from start: CGPoint, to location: CGPoint, in size: CGSize,
                               pose: PetPose, drawingSize: CGSize, centerOffset: CGSize) {
        let distance = CGSize(width: location.x - start.x, height: location.y - start.y)
        let isHorizontal = abs(distance.width) >= 16 && abs(distance.width) > abs(distance.height) * 1.5
        if !director.isPetting {
            guard isHorizontal else { return }
            // Sample across the stroke so it can begin beside the eyes and cross them.
            let steps = max(1, Int(ceil(abs(distance.width) / 12)))
            guard (0...steps).contains(where: { step in
                let progress = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(x: start.x + distance.width * progress, y: start.y + distance.height * progress)
                guard let local = facePoint(at: point, in: size, pose: pose,
                                            drawingSize: drawingSize, centerOffset: centerOffset) else { return false }
                return hitEye(at: local, pose: pose) != nil
            }) else { return }
        }
        director.pet(toward: touchPoint(location, in: size), distance: abs(distance.width))
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

    private func controls(_ homePanel: HomePanel) -> some View {
        NavigationStack(path: $activityPath) {
            Group {
                switch homePanel {
                case .play: playHome
                case .settings: settingsHome
                }
            }
            .navigationTitle(homePanel == .play ? "玩法" : "设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { activePanel = nil }
                }
            }
            .navigationDestination(for: ActivityPage.self) { page in
                Group {
                    switch page {
                    case .focus:
                        PetFocusPanel(timer: director.focusTimer, onPlay: { activityPath.append(.game) },
                                      onClose: { activePanel = nil })
                    case .game:
                        PetCatchGame(onExit: { _ = activityPath.popLast() })
                            .toolbar(.hidden, for: .navigationBar)
                    case .expressionPrograms:
                        panel { expressionShowSettings }
                            .navigationTitle("表情秀")
                    case .morePlay:
                        morePlay
                            .navigationTitle("更多玩法")
                    case .gestures:
                        panel { interactionGuide }
                            .navigationTitle("手势指南")
                    case .petProfile:
                        Form { petProfileSettings }
                            .scrollContentBackground(.hidden)
                            .background(panelBackground)
                            .navigationTitle("圆圆的名字与性格")
                    case .audio:
                        panel {
                            voiceCommandSettings
                            voicePlaybackSettings
                        }
                        .navigationTitle("声音与唤醒")
                        .onDisappear {
                            director.voice.stopPreview()
                            expressionSoundPreviewFailed = false
                        }
                    case .services:
                        panel { voiceServiceSettings }
                            .navigationTitle("语音服务")
                        .onDisappear(perform: clearKeyEditing)
                    case .systemPresence:
                        panel { systemPresenceSettings }
                            .navigationTitle("灵动岛与通知")
                    }
                }
                .navigationBarBackButtonHidden()
                .toolbar {
                    if page != .game {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                _ = activityPath.popLast()
                            } label: {
                                Label("返回", systemImage: "chevron.left")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }
            }
        }
        .tint(Color(red: 0.75, green: 0.69, blue: 1))
    }

    private var playHome: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10),
                            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
        return panel {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(PetMode.allCases) { choice in
                    modeCard(choice)
                }
            }
            NavigationLink(value: ActivityPage.morePlay) {
                HStack {
                    Label("更多玩法", systemImage: "square.grid.2x2")
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.white.opacity(0.07))
                        .strokeBorder(.white.opacity(0.09))
                }
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(PlayCardButtonStyle())
        }
    }

    private func modeCard(_ choice: PetMode) -> some View {
        let selected = mode == choice
        let symbol: String
        let detail: String
        let tint: Color
        switch choice {
        case .normal:
            symbol = "face.smiling"
            detail = "自动轮播 35 个表情"
            tint = Color(red: 0.75, green: 0.65, blue: 1)
        case .companion:
            symbol = "heart.fill"
            detail = "安静待机，碰一碰就回应"
            tint = Color(red: 1, green: 0.64, blue: 0.77)
        case .battery:
            symbol = "battery.50percent"
            detail = "用表情显示电量"
            tint = Color(red: 0.46, green: 0.9, blue: 0.73)
        case .nightLight:
            symbol = "moon.stars.fill"
            detail = "留一盏暖灯"
            tint = Color(red: 1, green: 0.76, blue: 0.45)
        }

        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return Button {
            mode = choice
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(
                                LinearGradient(colors: [tint.opacity(0.52), tint.opacity(0.15)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .strokeBorder(.white.opacity(0.18))
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.title)
                        .font(.headline)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .padding(.trailing, 24)
            .frame(minHeight: 74)
            .background {
                shape
                    .fill(
                        LinearGradient(colors: [tint.opacity(selected ? 0.27 : 0.19), tint.opacity(0.055)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .strokeBorder(selected ? tint.opacity(0.78) : tint.opacity(0.23),
                                  lineWidth: selected ? 1.5 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tint)
                        .padding(10)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(PlayCardButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(choice.title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var morePlay: some View {
        panel {
            if mode == .nightLight { nightLightSettings }
            playSection("表情与游戏") {
                NavigationLink(value: ActivityPage.expressionPrograms) { playTile("表情秀", symbol: "play.rectangle.fill", tint: .pink, opensPage: true) }
                    .disabled(director.focusTimer.isFocusing)
                ForEach(PetDirector.PlayActivity.allCases) { activity in
                    Button {
                        pendingPlayActivity = activity
                        activePanel = nil
                    } label: {
                        playTile(activity.rawValue, symbol: activity == .bubbles ? "bubbles.and.sparkles" : "hand.raised.fill",
                                 tint: activity == .bubbles ? .cyan : .orange)
                    }
                    .disabled(!voiceAvailable || director.focusTimer.isFocusing)
                }
                NavigationLink(value: ActivityPage.game) { playTile("扔球接球", symbol: "tennisball.fill", tint: .green, opensPage: true) }
                Button {
                    pendingMarch = true
                    activePanel = nil
                } label: { playTile("听圆圆唱歌", symbol: "music.note", tint: .pink) }
                .disabled(!voiceAvailable || director.focusTimer.isFocusing)
            }
            playSection("陪伴与感应") {
                NavigationLink(value: ActivityPage.focus) {
                    playTile(director.focusTimer.isFocusing ? "查看专注" : "番茄钟",
                             symbol: "timer", tint: .orange, opensPage: true)
                }
                Button {
                    visionEnabled.toggle()
                    activePanel = nil
                } label: {
                    playTile(visionEnabled ? "关闭隔空" : "隔空互动", symbol: "eye.fill", tint: .cyan, isActive: visionEnabled)
                }
                .disabled(!visionEnabled && (!voiceAvailable || director.focusTimer.isFocusing))
                Button {
                    motion.toggle()
                    activePanel = nil
                } label: {
                    playTile(motion ? "关闭体感" : "摇一摇", symbol: "iphone.gen3.radiowaves.left.and.right",
                             tint: .blue, isActive: motion)
                }
                .disabled(!motion && (mode == .nightLight || director.focusTimer.isFocusing))
                Button {
                    sound.toggle()
                    activePanel = nil
                } label: {
                    playTile(sound ? "关闭声音感应" : "拍手与吹气", symbol: "waveform", tint: .mint, isActive: sound)
                }
                .disabled(!sound && (mode == .nightLight || director.focusTimer.isFocusing))
            }
            NavigationLink(value: ActivityPage.gestures) {
                playTile("手势指南", symbol: "hand.draw.fill", tint: .indigo, opensPage: true)
            }
            .buttonStyle(PlayCardButtonStyle())
            Divider().overlay(.white.opacity(0.07))
            expressionLibrary
        }
    }

    private func playSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 300 : 195), spacing: 8)], spacing: 8, content: content)
                .buttonStyle(PlayCardButtonStyle())
        }
    }

    private var settingsHome: some View {
        Form {
            Section("日常偏好") {
                Toggle(isOn: $proactiveGreetings) { panelLabel("主动问候", symbol: "sun.max.fill", tint: .orange) }
                Toggle(isOn: $keepAwake) { panelLabel("屏幕常亮", symbol: "sun.horizon.fill", tint: .yellow) }
                Toggle(isOn: $showMouth) { panelLabel("显示嘴巴", symbol: "face.smiling", tint: .pink) }
                Toggle(isOn: $lightweightDisplay) { panelLabel("省电显示", symbol: "leaf.fill", tint: .green) }
                Text("简化边缘光效，降低待机刷新频率。系统低电量或设备过热时也会自动启用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("圆圆与语音") {
                NavigationLink(value: ActivityPage.petProfile) {
                    LabeledContent {
                        Text(displayName).lineLimit(1)
                    } label: {
                        panelLabel("名字与性格", symbol: "person.crop.circle.fill", tint: .purple)
                    }
                }
                NavigationLink(value: ActivityPage.audio) {
                    panelLabel("声音与唤醒", symbol: "speaker.wave.2.fill", tint: .pink)
                }
                NavigationLink(value: ActivityPage.services) {
                    LabeledContent {
                        Text(director.voice.hasDeepSeekKey || director.voice.hasDoubaoKey ? "已配置" : "本机")
                    } label: {
                        panelLabel("语音服务", symbol: "waveform", tint: .blue)
                    }
                }
            }
            Section("系统") {
                NavigationLink(value: ActivityPage.systemPresence) {
                    panelLabel("灵动岛与通知", symbol: "bell.fill", tint: .indigo)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(panelBackground)
    }

    private var petProfileSettings: some View {
        Section {
            TextField("宠物名字", text: $petName)
                .accessibilityLabel("宠物名字")
            Picker("性格", selection: $personality) {
                ForEach(["黏人", "傲娇", "元气", "自定义"], id: \.self) { choice in Text(choice) }
            }
            if personality == "自定义" {
                TextField("用一句话描述它的性格", text: $customPersonality)
            }
        } footer: {
            Text("名字用于首页和语音唤醒。自由聊天会使用所选性格。")
        }
    }

    private func clearKeyEditing() {
        keyCheckTask?.cancel()
        keyCheckTask = nil
        checkingKey = nil
        keyInputs.removeAll()
        keyMessages.removeAll()
    }

    private var systemPresenceSettings: some View {
        settingsSection("灵动岛与消息提醒") {
            Toggle("灵动岛陪伴", isOn: $liveCompanion)
                .onChange(of: liveCompanion) { _, enabled in
                    Task { await systemPresence.syncCompanion(enabled: enabled, name: displayName) }
                }
            .disabled(systemPresence.changingCompanion)
            if liveCompanion, systemPresence.isCompanionActive {
                Label("陪伴中", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            settingsNote("有灵动岛的机型可在岛上看到圆圆，其他支持实时活动的机型可在锁屏查看。")
            Text("刘海屏预览")
                .font(.subheadline.weight(.semibold))
            notchEyePreview

            Toggle("消息通知横幅", isOn: Binding {
                messageBanners
            } set: { enabled in
                if enabled {
                    Task { messageBanners = await systemPresence.enableMessageBanners() }
                } else {
                    messageBanners = false
                }
            })
            settingsNote("在「快捷指令」的自动化里添加「提醒圆圆有新消息」，并在「来源 App」填写应用名，例如「信息」或「邮件」。")
            Button("试一下消息提醒") {
                activePanel = nil
                Task { await previewMessageReminder(sourceApp: "信息") }
            }
            .buttonStyle(.bordered)

            if let notice = systemPresence.notice { permissionLink(notice) }
        }
    }

    private var notchEyePreview: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let gaze = reduceMotion ? 0 : sin(time * .pi / 2)
            let blinkTime = abs(time.truncatingRemainder(dividingBy: 4.8) - 4.5)
            let openness = reduceMotion ? 1 : min(1, 0.16 + blinkTime / 0.13)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    PetCompanionEye(width: 14, gaze: gaze, openness: openness, animatesGaze: false)
                    UnevenRoundedRectangle(bottomLeadingRadius: 15, bottomTrailingRadius: 15)
                        .fill(.black)
                        .frame(width: 108, height: 25)
                        .overlay {
                            Capsule().fill(.white.opacity(0.14)).frame(width: 24, height: 2)
                        }
                    PetCompanionEye(width: 14, gaze: gaze, openness: openness, animatesGaze: false)
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .top)

                PetCompanionCard(name: displayName, status: "正在陪伴你", hasMessage: false,
                                 gaze: gaze, openness: openness, animatesGaze: false)
            }
            .background(PetCompanionCard.background, in: RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityRepresentation { Text("\(displayName)正在陪伴你。刘海两侧的眼睛左右张望并眨眼。") }
    }

    private func previewMessageReminder(sourceApp: String? = nil) async {
        await systemPresence.requestBannerPermissionIfNeeded()
        try? await systemPresence.receiveMessage(sourceApp: sourceApp)
    }

    private var panelBackground: some View {
        LinearGradient(
            colors: [Color(red: 0.12, green: 0.105, blue: 0.20),
                     Color(red: 0.055, green: 0.06, blue: 0.10),
                     Color(red: 0.036, green: 0.038, blue: 0.062)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14, content: content)
                .frame(maxWidth: 650)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .background(panelBackground)
    }

    private func panelIcon(_ symbol: String, tint: Color, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.49, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.26)
                    .fill(
                        LinearGradient(colors: [tint.opacity(0.65), tint.opacity(0.22)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .strokeBorder(.white.opacity(0.12))
            }
            .accessibilityHidden(true)
    }

    private func panelLabel(_ title: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            panelIcon(symbol, tint: tint, size: 29)
            Text(title)
        }
    }

    private func playTile(_ title: String, symbol: String, tint: Color = .purple,
                          opensPage: Bool = false, isActive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return HStack(spacing: 9) {
            panelIcon(symbol, tint: tint, size: 34)
            Text(title)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(tint)
                    .accessibilityLabel("已开启")
            } else if opensPage {
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 48)
        .background {
            shape
                .fill(
                    LinearGradient(colors: [tint.opacity(isActive ? 0.25 : 0.13), .white.opacity(0.045)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .strokeBorder(isActive ? tint.opacity(0.62) : .white.opacity(0.10))
        }
        .contentShape(shape)
    }

    private var expressionLibrary: some View {
        let groups = PetExpression.groups
        let categoryNames = ["心情", "动作", "彩蛋"]
        let expressions = expressionCategory == 0 ? PetExpression.quickExpressions : groups[expressionCategory - 1].expressions
        let tint: Color = switch expressionCategory {
        case 2: .cyan
        case 3: .orange
        default: .purple
        }
        let unavailableReason: String? = if director.focusTimer.isFocusing {
            "专注结束后可以播放表情。"
        } else if mode == .nightLight {
            "退出夜灯后可以播放表情。"
        } else {
            nil
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("选表情")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let unavailableReason { settingsNote(unavailableReason) }
            Picker("表情分类", selection: $expressionCategory) {
                Text("常用").tag(0)
                ForEach(groups.indices, id: \.self) { index in
                    Text(categoryNames[index]).tag(index + 1)
                }
            }
            .pickerStyle(.segmented)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 250 : 142), spacing: 8)], spacing: 8) {
                ForEach(expressions) { expression in
                    Button {
                        pendingExpression = expression
                        activePanel = nil
                    } label: {
                        playTile(expression.rawValue, symbol: expression.symbol, tint: tint)
                    }
                }
            }
            .buttonStyle(PlayCardButtonStyle())
            .disabled(unavailableReason != nil)
            if expressionCategory == 0 && unavailableReason == nil {
                settingsNote("点首页空白处看下一个，双指左右滑可以前后切换。")
            }
        }
    }

    private var nightLightSettings: some View {
        settingsSection("夜灯") {
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

    private var expressionShowSettings: some View {
        settingsSection("选择节目") {
            ForEach(PetExpressionShow.allCases) { program in
                Button {
                    pendingExpressionShow = program
                    activePanel = nil
                } label: {
                    HStack(spacing: 10) {
                        panelIcon("play.fill", tint: .pink, size: 34)
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

    private var interactionGuide: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSection("触屏") {
                settingsNote("点圆圆的脸或摸摸它，点空白处换表情。")
                settingsNote("双指左右滑换表情，三指上滑放彩带。单指上滑开始聊天。")
            }
            settingsSection("隔空与感应") {
                settingsNote("点首页右下角的眼睛开启隔空互动。挥手打招呼，伸食指戳泡泡，举掌停稳后向前推可以击掌。也可以比心、点赞，或张掌后收拢手指开始聊天。")
                settingsNote("体感：摇一摇、倾斜手机，或翻面让圆圆睡觉。")
                settingsNote("声音：试试拍手、吹气，或放一段有节奏的音乐。夜灯和专注期间会暂停感应。")
                if motion && director.senses.motionUnavailable { settingsNote("当前设备无法使用运动传感器。") }
                if sound && director.audio.microphoneDenied { permissionLink("麦克风权限未开启") }
            }
        }
    }

    private var voiceServiceSettings: some View {
        settingsSection("云端服务（可选）") {
            apiKeySettings(.deepSeek, configured: director.voice.hasDeepSeekKey,
                           detail: "生成聊天回复。自由聊天会发送转写文字和近期对话。")
            TextField("模型名称", text: $model, prompt: Text(DeepSeekClient.defaultModel))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .disabled(checkingKey == .deepSeek)
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
            Button {
                if director.voice.isPreviewing {
                    director.voice.stopPreview()
                } else {
                    director.prepareForVoiceInput()
                    director.voice.previewVoice()
                }
            } label: {
                playTile(director.voice.isPreviewing ? "停止试听" : "试听当前音色",
                         symbol: director.voice.isPreviewing ? "stop.fill" : "play.fill", tint: .pink)
            }
            .buttonStyle(PlayCardButtonStyle())
        }
    }

    private var voiceCommandSettings: some View {
        settingsSection("唤醒与音效") {
            Toggle(isOn: $voiceWakeEnabled) {
                panelLabel("喊名字唤醒", symbol: "mic.fill", tint: .purple)
            }
            settingsNote("开启后，麦克风只在主画面用本机识别名字。说「嘿，\(displayName)」，停一下再说指令。")
            Toggle(isOn: $expressionSounds) {
                panelLabel("表情音效", symbol: "speaker.wave.2.fill", tint: .pink)
            }
            .onChange(of: expressionSounds) { _, _ in expressionSoundPreviewFailed = false }
            settingsNote("开启后，35 个表情各有短音效。静音模式下也会播放，音量跟随 iPhone 的媒体音量。")
            Button {
                director.configure(settings)
                expressionSoundPreviewFailed = !director.previewExpressionSound()
            } label: {
                playTile("试听表情音效", symbol: "play.fill", tint: .purple)
            }
            .buttonStyle(PlayCardButtonStyle())
            .disabled(!expressionSounds)
            if expressionSounds && expressionSoundPreviewFailed {
                settingsNote("暂时无法播放，请稍后再试。")
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

private struct PlayCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct PetTouchSurface: UIViewRepresentable {
    enum Event {
        case tap(CGPoint), longPress, stroke(CGPoint, CGPoint), strokeEnded(upward: Bool), cancelled
        case browse(Int), celebrate, tracking(CGSize), contact(Bool)
    }

    let handle: (Event) -> Void

    func makeUIView(context: Context) -> Surface {
        let surface = Surface(frame: .zero)
        surface.isMultipleTouchEnabled = true
        return surface
    }

    func updateUIView(_ view: Surface, context: Context) {
        view.handle = handle
    }

    final class Surface: UIView {
        var handle: ((Event) -> Void)?
        private var starts: [UITouch: CGPoint] = [:]
        private var active: Set<UITouch> = []
        private var swipe: Event?
        private var firstTouchAt: TimeInterval?
        private var didLift = false
        private var invalidated = false
        private var longPressed = false
        private var moved = false
        private var longPress: Task<Void, Never>?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let isFirstContact = active.isEmpty
            active.formUnion(touches)
            if isFirstContact { handle?(.contact(true)) }
            let timestamp = touches.map(\.timestamp).min() ?? 0
            if firstTouchAt == nil { firstTouchAt = timestamp }
            if didLift || timestamp - (firstTouchAt ?? timestamp) > 0.24 { invalidated = true }
            for touch in touches { starts[touch] = touch.location(in: self) }
            if starts.count > 1 {
                longPress?.cancel()
                if moved { handle?(.cancelled) }
            } else {
                longPress = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                    guard let self, active.count == 1, !moved else { return }
                    longPressed = true
                    handle?(.longPress)
                }
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard !invalidated, !longPressed, !didLift else { return }
            if starts.count > 1 {
                handle?(.tracking(Self.previewOffset(for: offsets)))
            } else if let touch = touches.first, let start = starts[touch] {
                trackStroke(from: start, to: touch.location(in: self))
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            longPress?.cancel()
            if starts.count > 1 && !didLift && !longPressed {
                swipe = Self.swipe(for: offsets)
            }
            didLift = true
            active.subtract(touches)
            guard active.isEmpty else { return }
            defer {
                reset()
                handle?(.contact(false))
            }
            guard !invalidated && !longPressed else {
                handle?(.cancelled)
                return
            }
            if starts.count > 1 {
                handle?(swipe ?? .cancelled)
            } else if let touch = touches.first, let start = starts[touch] {
                let point = touch.location(in: self)
                trackStroke(from: start, to: point)
                if moved {
                    let up = start.y - point.y
                    handle?(.strokeEnded(upward: up >= 52 && up >= abs(point.x - start.x) * 1.5))
                } else {
                    handle?(.tap(point))
                }
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            invalidated = true
            didLift = true
            longPress?.cancel()
            handle?(.cancelled)
            active.subtract(touches)
            if active.isEmpty {
                reset()
                handle?(.contact(false))
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                let hadContact = !active.isEmpty
                reset()
                if hadContact {
                    Task { [handle] in
                        handle?(.cancelled)
                        handle?(.contact(false))
                    }
                }
            }
        }

        private func trackStroke(from start: CGPoint, to point: CGPoint) {
            if hypot(point.x - start.x, point.y - start.y) > 12 {
                moved = true
                longPress?.cancel()
            }
            if moved { handle?(.stroke(start, point)) }
        }

        private var offsets: [CGSize] {
            starts.map { touch, start in
                let point = touch.location(in: self)
                return CGSize(width: point.x - start.x, height: point.y - start.y)
            }
        }

        private static func previewOffset(for offsets: [CGSize]) -> CGSize {
            if offsets.count == 2 {
                for direction: CGFloat in [-1, 1] where offsets.allSatisfy({ $0.width * direction > abs($0.height) * 1.5 }) {
                    let travel = offsets.map { $0.width * direction }.min() ?? 0
                    return CGSize(width: direction * min(18, max(0, travel - 8) * 0.3), height: 0)
                }
            }
            if offsets.count == 3 && offsets.allSatisfy({ -$0.height > abs($0.width) * 1.5 }) {
                let travel = offsets.map { -$0.height }.min() ?? 0
                return CGSize(width: 0, height: -min(14, max(0, travel - 8) * 0.25))
            }
            return .zero
        }

        private static func swipe(for offsets: [CGSize]) -> Event? {
            // Every finger must travel in the same direction; pinches and stationary fingers don't count.
            if offsets.count == 2 {
                for step in [1, -1] where offsets.allSatisfy({ offset in
                    let forward = -offset.width * CGFloat(step)
                    return forward >= 44 && forward >= abs(offset.height) * 1.5
                }) {
                    return .browse(step)
                }
            }
            if offsets.count == 3 && offsets.allSatisfy({
                -$0.height >= 52 && -$0.height >= abs($0.width) * 1.5
            }) {
                return .celebrate
            }
            return nil
        }

        private func reset() {
            longPress?.cancel()
            longPress = nil
            starts.removeAll()
            active.removeAll()
            swipe = nil
            firstTouchAt = nil
            didLift = false
            invalidated = false
            longPressed = false
            moved = false
        }
    }
}
