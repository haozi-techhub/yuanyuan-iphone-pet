import ActivityKit
import AppIntents
import Foundation

nonisolated struct PetLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Reaction: String, Codable {
            case happy, wink, curious

            var next: Self {
                switch self {
                case .happy: .wink
                case .wink: .curious
                case .curious: .happy
                }
            }
        }

        var hasNewMessage: Bool
        var looksRight: Bool?
        var sourceApp: String?
        var reaction: Reaction?

        var gaze: CGFloat { hasNewMessage || looksRight == true ? 1 : -1 }
        var status: String {
            hasNewMessage ? Self.messageText(sourceApp: sourceApp) : "正在陪伴你"
        }

        static func messageText(sourceApp: String?) -> String {
            if let sourceApp { return "\(sourceApp) 有新消息" }
            return "你有一条新消息"
        }
    }

    let petName: String

    static let openURL = URL(string: "yuanyuan-pet://live-activity")!
}

nonisolated struct PetLookAroundIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "逗一下圆圆"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        guard let activity = Activity<PetLiveActivityAttributes>.activities.first(where: {
            $0.activityState == .active || $0.activityState == .stale
        }) else { return .result() }
        var state = activity.content.state
        if !state.hasNewMessage {
            state.looksRight = state.looksRight != true
            state.reaction = state.reaction?.next ?? .happy
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        return .result()
    }
}
