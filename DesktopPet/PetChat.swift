import SwiftUI

enum PetGreetingPeriod: Equatable {
    case morning, lunch

    init?(hour: Int) {
        switch hour {
        case 5..<11: self = .morning
        case 11..<14: self = .lunch
        default: return nil
        }
    }

    var greeting: String {
        switch self {
        case .morning: "早安！今天想做点什么？"
        case .lunch: "吃午饭了没？记得休息一下。"
        }
    }

    static func greeting(at now: Date, after lastGreeting: Date?, calendar: Calendar = .current) -> String? {
        guard let period = Self(hour: calendar.component(.hour, from: now)) else { return nil }
        if let lastGreeting, calendar.isDate(lastGreeting, inSameDayAs: now),
           Self(hour: calendar.component(.hour, from: lastGreeting)) == period || lastGreeting > now {
            return nil
        }
        return period.greeting
    }

}

struct PetConversationBubble: View {
    let name: String
    let transcript: String
    let message: String?
    let status: String?

    var body: some View {
        ViewThatFits(in: .vertical) {
            conversation
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                conversation
            }
            .defaultScrollAnchor(.bottom)
        }
        .frame(maxHeight: 128, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .modifier(PetConversationGlass())
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !transcript.isEmpty { line(transcript, speaker: "你") }
            if let message { line(message, speaker: name) }
            if let status {
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }

    private func line(_ text: String, speaker: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(speaker)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.title2.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

}

private struct PetConversationGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
