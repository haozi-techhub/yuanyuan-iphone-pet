import ActivityKit
import AppIntents
import Observation
import OSLog
import UIKit
import UserNotifications

@Observable @MainActor
final class PetSystemPresence {
    static let shared = PetSystemPresence()
    static let notificationTitle = "圆圆桌宠"
    static let legacyMessageURL = URL(string: "yuanyuan-pet://message-received")!
    static let bannerPreference = "pet.messageNotificationBanners"
    static let companionPreference = "pet.liveCompanionEnabled"
    nonisolated static let messageNotificationID = "pet.messageReminder"
    private let logger = Logger(subsystem: "com.haozi.desktoppet", category: "SystemPresence")

    private(set) var isCompanionActive = false
    private(set) var messageEvent: Date?
    private(set) var messageText = "你有一条新消息"
    private(set) var notice: String?
    private(set) var changingCompanion = false
    private var requestingBannerPermission = false

    private typealias Companion = Activity<PetLiveActivityAttributes>
    nonisolated private static var companion: Companion? {
        Companion.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    private init() {}

    func refreshCompanion() {
        isCompanionActive = Self.companion != nil
    }

    func syncCompanion(enabled: Bool, name: String) async {
        refreshCompanion()
        guard !changingCompanion else { return }
        changingCompanion = true
        defer {
            changingCompanion = false
            refreshCompanion()
        }
        notice = nil
        guard enabled else {
            await Self.endCompanion()
            return
        }
        guard !isCompanionActive else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            notice = "请在 iPhone 设置中允许圆圆的实时活动。"
            logger.notice("Live Activities are disabled on this iPhone.")
            return
        }
        do {
            let attributes = PetLiveActivityAttributes(petName: String(name.prefix(24)))
            let content = ActivityContent(state: PetLiveActivityAttributes.ContentState(hasNewMessage: false),
                                          staleDate: nil)
            let activity = try Companion.request(attributes: attributes, content: content, pushType: nil)
            logger.notice("Started Live Activity \(activity.id, privacy: .public)")
        } catch {
            logger.error("Live Activity failed: \(String(describing: error), privacy: .public)")
            notice = "暂时无法开启实时活动，请稍后再试。"
        }
    }

    func receiveMessage(sourceApp: String? = nil) async throws {
        let name = sourceApp?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let source = name.flatMap { $0.isEmpty ? nil : String($0.prefix(24)) }
        messageText = PetLiveActivityAttributes.ContentState.messageText(sourceApp: source)
        messageEvent = .now
        let updatedActivity = await Self.updateMessageBadge(true, sourceApp: source)

        if UserDefaults.standard.object(forKey: Self.bannerPreference) as? Bool ?? true {
            do {
                try await postMessageBanner(sourceApp: source)
            } catch {
                if !updatedActivity { throw error }
            }
        } else if !updatedActivity && UIApplication.shared.applicationState != .active {
            throw MessageReminderError.noDestination
        }
    }

    func openCompanion() async {
        guard let state = Self.companionState(), state.hasNewMessage else { return }
        messageText = state.status
        messageEvent = .now
        _ = await Self.updateMessageBadge(false)
    }

    nonisolated private static func companionState() -> PetLiveActivityAttributes.ContentState? {
        companion?.content.state
    }

    nonisolated private static func endCompanion() async {
        guard let companion else { return }
        await companion.end(nil, dismissalPolicy: .immediate)
    }

    nonisolated private static func updateMessageBadge(_ hasNewMessage: Bool, sourceApp: String? = nil) async -> Bool {
        guard let companion, hasNewMessage || companion.content.state.hasNewMessage else { return false }
        var state = companion.content.state
        state.hasNewMessage = hasNewMessage
        state.sourceApp = sourceApp
        let content = ActivityContent(state: state, staleDate: nil)
        await companion.update(content)
        return true
    }

    func openMessageBanner(text: String) async {
        messageText = text
        messageEvent = .now
        _ = await Self.updateMessageBadge(false)
    }

    func enableMessageBanners() async -> Bool {
        guard !requestingBannerPermission else { return false }
        requestingBannerPermission = true
        defer { requestingBannerPermission = false }
        do {
            let center = UNUserNotificationCenter.current()
            if try await center.requestAuthorization(options: [.alert, .sound]) {
                notice = nil
                return true
            }
            notice = "请在 iPhone 设置中允许圆圆发送通知。"
        } catch {
            notice = "暂时无法开启系统通知，请稍后再试。"
        }
        return false
    }

    func requestBannerPermissionIfNeeded() async {
        guard UserDefaults.standard.object(forKey: Self.bannerPreference) as? Bool ?? true,
              await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = await enableMessageBanners()
    }

    private func postMessageBanner(sourceApp: String?) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        default:
            throw MessageReminderError.notificationsDisabled
        }
        let content = UNMutableNotificationContent()
        content.title = Self.notificationTitle
        content.body = PetLiveActivityAttributes.ContentState.messageText(sourceApp: sourceApp)
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: Self.messageNotificationID, content: content, trigger: nil))
        logger.notice("Scheduled pet message notification.")
    }
}

private enum MessageReminderError: LocalizedError {
    case noDestination
    case notificationsDisabled

    var errorDescription: String? {
        switch self {
        case .noDestination: "请先开启圆圆的实时活动或系统消息提醒。"
        case .notificationsDisabled: "请在 iPhone 设置中允许圆圆发送通知。"
        }
    }
}

struct PetMessageReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "提醒圆圆有新消息"
    static let description = IntentDescription("填写来源 App 名称，例如微信或信息。此动作无需传入消息正文。")
    static let openAppWhenRun = false

    @Parameter(title: "来源 App")
    var sourceApp: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PetSystemPresence.shared.receiveMessage(sourceApp: sourceApp)
        return .result()
    }
}

struct PetAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PetMessageReminderIntent(),
                    phrases: ["让\(.applicationName)提醒我有新消息"],
                    shortTitle: "提醒圆圆有新消息",
                    systemImageName: "envelope.badge")
    }
}
