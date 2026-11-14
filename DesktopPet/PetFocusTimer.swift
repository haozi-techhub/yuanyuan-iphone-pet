import Foundation
import Observation
import SwiftUI
import UserNotifications

@Observable @MainActor
final class PetFocusTimer {
    fileprivate enum Phase: String, Codable {
        case focus, rest

        var title: String { self == .focus ? "专注" : "休息" }
        var duration: TimeInterval { self == .focus ? 25 * 60 : 5 * 60 }
        var completionTitle: String { self == .focus ? "专注完成" : "休息结束" }
    }

    fileprivate struct Session: Codable {
        enum State: Codable {
            case running(deadline: Date, reminderID: UUID)
            case paused(remaining: TimeInterval)
            case complete
        }

        let id: UUID
        let phase: Phase
        var state: State
    }

    private struct SavedTimer: Codable {
        let session: Session?
        let focusCelebrationPending: Bool
    }

    private static let storageKey = "pet.focusTimer.v1"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let notificationCenter: UNUserNotificationCenter?
    @ObservationIgnored private var reminderTask: Task<Void, Never>?
    @ObservationIgnored private var focusCelebrationPending = false

    fileprivate private(set) var session: Session?
    fileprivate private(set) var remainingSeconds = 0
    fileprivate private(set) var backgroundReminderUnavailable = false

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { .now },
         notificationCenter: UNUserNotificationCenter? = .current()) {
        self.defaults = defaults
        self.now = now
        self.notificationCenter = notificationCenter

        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(SavedTimer.self, from: data) {
            session = saved.session
            focusCelebrationPending = saved.focusCelebrationPending
        }
        switch session?.state {
        case .running(let deadline, _): updateRemaining(deadline.timeIntervalSince(now()))
        case .paused(let remaining): updateRemaining(remaining)
        case .complete, nil: break
        }
    }

    var isFocusing: Bool {
        guard let session, session.phase == .focus, case .running = session.state else { return false }
        return true
    }

    var statusText: String? {
        guard let session else { return nil }
        switch session.state {
        case .running: return "\(session.phase.title) \(remainingText)"
        case .paused: return "\(session.phase.title)已暂停"
        case .complete: return session.phase.completionTitle
        }
    }

    fileprivate var remainingText: String {
        Duration.seconds(remainingSeconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
    }

    func refresh() {
        guard var session, case .running(let deadline, let id) = session.state else { return }
        let remaining = deadline.timeIntervalSince(now())
        updateRemaining(remaining)
        guard remaining <= 0 else {
            if reminderTask == nil { scheduleCurrentReminder() }
            return
        }

        cancelReminder(id)
        session.state = .complete
        self.session = session
        if session.phase == .focus { focusCelebrationPending = true }
        save()
    }

    func consumeFocusCelebration() -> Bool {
        guard focusCelebrationPending else { return false }
        focusCelebrationPending = false
        save()
        return true
    }

    func startFocus() {
        guard canStartPhase else { return }
        focusCelebrationPending = false
        start(.focus, roundID: UUID())
    }

    func startRest() {
        guard let session, session.phase == .focus, case .complete = session.state else { return }
        start(.rest, roundID: session.id)
    }

    func pause() {
        refresh()
        guard var session, case .running(let deadline, let id) = session.state else { return }
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else { refresh(); return }

        cancelReminder(id)
        session.state = .paused(remaining: remaining)
        self.session = session
        updateRemaining(remaining)
        save()
    }

    func resume() {
        guard var session, case .paused(let remaining) = session.state else { return }
        session.state = runningState(for: remaining)
        self.session = session
        save()
        scheduleCurrentReminder()
    }

    func end() {
        refresh()
        if case .running(_, let id) = session?.state { cancelReminder(id) }
        session = nil
        updateRemaining(0)
        backgroundReminderUnavailable = false
        save()
    }

    private var canStartPhase: Bool {
        if case .complete = session?.state { return true }
        return session == nil
    }

    private func start(_ phase: Phase, roundID: UUID) {
        session = Session(id: roundID, phase: phase, state: runningState(for: phase.duration))
        updateRemaining(phase.duration)
        save()
        scheduleCurrentReminder()
    }

    private func runningState(for duration: TimeInterval) -> Session.State {
        .running(deadline: now().addingTimeInterval(duration), reminderID: UUID())
    }

    private func updateRemaining(_ remaining: TimeInterval) {
        let seconds = max(0, Int(ceil(remaining)))
        if seconds != remainingSeconds { remainingSeconds = seconds }
    }

    private func save() {
        let saved = SavedTimer(session: session, focusCelebrationPending: focusCelebrationPending)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.storageKey) }
    }

    private func isCurrentReminder(_ id: UUID) -> Bool {
        guard case .running(_, let currentID) = session?.state else { return false }
        return id == currentID
    }

    private func reminderIdentifier(_ id: UUID) -> String {
        "pet.focusTimer.\(id.uuidString)"
    }

    private func cancelReminder(_ id: UUID) {
        reminderTask?.cancel()
        reminderTask = nil
        notificationCenter?.removePendingNotificationRequests(withIdentifiers: [reminderIdentifier(id)])
    }

    private func scheduleCurrentReminder() {
        guard let center = notificationCenter, let session,
              case .running(let deadline, let id) = session.state else { return }
        backgroundReminderUnavailable = false
        let identifier = reminderIdentifier(id)
        let title = session.phase.completionTitle
        let body = session.phase == .focus ? "可以休息 5 分钟了。" : "准备好后，可以开始下一轮专注。"

        reminderTask = Task { [weak self] in
            do {
                var settings = await center.notificationSettings()
                guard !Task.isCancelled, self?.isCurrentReminder(id) == true else { return }
                if settings.authorizationStatus == .notDetermined {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                    guard !Task.isCancelled, self?.isCurrentReminder(id) == true else { return }
                    settings = await center.notificationSettings()
                }
                guard !Task.isCancelled, self?.isCurrentReminder(id) == true else { return }
                guard settings.authorizationStatus != .denied, settings.authorizationStatus != .notDetermined else {
                    self?.backgroundReminderUnavailable = true
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    return
                }
                guard let currentTime = self?.now() else { return }
                let remaining = deadline.timeIntervalSince(currentTime)
                guard remaining > 0 else { return }

                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                // The request can finish registering after the user pauses or ends this interval.
                if Task.isCancelled || self?.isCurrentReminder(id) != true {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                }
            } catch {
                if self?.isCurrentReminder(id) == true { self?.backgroundReminderUnavailable = true }
            }
        }
    }
}

struct PetFocusPanel: View {
    let timer: PetFocusTimer
    let onPlay: () -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                switch timer.session?.state {
                case nil:
                    Text("专注 25 分钟 · 休息 5 分钟")
                        .foregroundStyle(.secondary)
                    primaryButton("开始专注", action: startFocus)
                case .running:
                    timerDisplay
                    primaryButton("暂停", action: timer.pause)
                    Button("结束", role: .destructive, action: timer.end)
                    if timer.isFocusing {
                        Button("玩一局", action: onPlay)
                        Text("专注计时继续")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("玩一局", action: onPlay)
                            .buttonStyle(.bordered)
                    }
                case .paused:
                    timerDisplay
                    primaryButton("继续", action: timer.resume)
                    Button("结束", role: .destructive, action: timer.end)
                case .complete:
                    if let title = timer.statusText {
                        Text(title)
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                    }
                    if timer.session?.phase == .focus {
                        primaryButton("开始 5 分钟休息", action: timer.startRest)
                        Button("再专注一轮", action: startFocus)
                    } else {
                        primaryButton("开始专注", action: startFocus)
                    }
                    Button("完成", action: timer.end)
                }

                if timer.backgroundReminderUnavailable {
                    Label("后台提醒不可用", systemImage: "bell.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("番茄钟")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("关闭", action: onClose)
            }
        }
    }

    private var timerDisplay: some View {
        VStack(spacing: 5) {
            if let session = timer.session {
                if case .paused = session.state {
                    Text("\(session.phase.title)已暂停")
                } else {
                    Text(session.phase.title)
                }
            }
            Text(timer.remainingText)
                .font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
                .accessibilityLabel("剩余 \(timer.remainingSeconds / 60) 分 \(timer.remainingSeconds % 60) 秒")
        }
    }

    private func startFocus() {
        timer.startFocus()
        onClose()
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}
