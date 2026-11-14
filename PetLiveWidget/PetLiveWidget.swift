import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PetLiveWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PetLiveActivityAttributes.self) { context in
            PetCompanionCard(name: context.attributes.petName, status: context.state.status,
                             hasMessage: context.state.hasNewMessage, gaze: context.state.gaze)
            .activityBackgroundTint(PetCompanionCard.background)
            .activitySystemActionForegroundColor(.white)
            .environment(\.colorScheme, .dark)
            .widgetURL(PetLiveActivityAttributes.openURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    PetExpandedIsland(name: context.attributes.petName, state: context.state)
                }
            } compactLeading: {
                PetCompanionEyes(eyeWidth: 8, gaze: context.state.gaze)
                    .accessibilityRepresentation { Text(context.attributes.petName) }
            } compactTrailing: {
                if context.state.hasNewMessage {
                    Group {
                        if let source = context.state.sourceApp {
                            Text(source)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .frame(maxWidth: 46)
                        } else {
                            Image(systemName: "envelope.fill")
                                .font(.system(size: 12))
                        }
                    }
                    .foregroundStyle(.yellow)
                    .accessibilityLabel(context.state.status)
                }
            } minimal: {
                PetCompanionEyes(eyeWidth: 7, gaze: context.state.gaze)
                    .overlay(alignment: .topTrailing) {
                        if context.state.hasNewMessage {
                            Circle().fill(.yellow).frame(width: 5, height: 5)
                                .offset(x: 2, y: -2)
                        }
                    }
                    .accessibilityRepresentation {
                        Text(context.state.hasNewMessage ? context.state.status : context.attributes.petName)
                    }
            }
            .widgetURL(PetLiveActivityAttributes.openURL)
            .keylineTint(petTint)
        }
    }

    private var petTint: Color { Color(red: 0.78, green: 0.71, blue: 1) }
}

private struct PetExpandedIsland: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let name: String
    let state: PetLiveActivityAttributes.ContentState

    private var title: String {
        if state.hasNewMessage { return state.status }
        switch state.reaction {
        case .happy: return "嘿，我在呢"
        case .wink: return "眨个眼"
        case .curious: return "再逗我一下？"
        case nil: return state.status
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            PetCompanionEyes(eyeWidth: 15, gaze: state.gaze,
                             reaction: state.hasNewMessage ? nil : state.reaction)
                .frame(width: 54)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.64))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: title)
                    .lineLimit(2)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if state.hasNewMessage {
                Link(destination: PetLiveActivityAttributes.openURL) {
                    Image(systemName: "envelope.fill")
                        .foregroundStyle(.black)
                }
                .buttonStyle(PetIslandActionStyle(fill: Color(red: 1, green: 0.85, blue: 0.52)))
                .accessibilityLabel("回到\(name)")
            } else {
                Button(intent: PetLookAroundIntent()) {
                    Image(systemName: "hand.tap.fill")
                        .foregroundStyle(.white)
                }
                .buttonStyle(PetIslandActionStyle(fill: .white.opacity(0.16)))
                .accessibilityLabel("逗一下\(name)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

private struct PetIslandActionStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 44, height: 44)
            .background(fill, in: Circle())
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.68 : 1)
    }
}
