import Foundation
import CoreGraphics

enum PetExpressionVariant: Int, CaseIterable, Codable {
    case original, second, third

    var next: Self {
        switch self {
        case .original: .second
        case .second: .third
        case .third: .original
        }
    }
}

enum PetExpression: String, CaseIterable, Codable, Identifiable {
    case idle = "待机"
    case happy = "开心"
    case angry = "生气"
    case proud = "骄傲"
    case sad = "难过"
    case crying = "哭泣"
    case surprised = "惊讶"
    case curious = "好奇"
    case celebrate = "庆祝"
    case delighted = "星星眼"
    case cool = "耍帅"
    case affectionate = "爱心眼"
    case sleepy = "犯困"
    case dizzy = "晕乎乎"
    case musical = "听歌"
    case greeting = "打招呼"
    case shy = "害羞"
    case laughing = "大笑"
    case winking = "眨眼卖萌"
    case listening = "我在听"
    case thinking = "思考"
    case confused = "满头问号"
    case peeking = "探头"
    case yawning = "打哈欠"
    case kiss = "飞吻"
    case hungry = "饿啦"
    case munching = "吃零食"
    case bubbles = "吹泡泡"
    case freezing = "冻住啦"
    case dancing = "蹦迪"
    case charging = "充电中"
    case charged = "充满电"
    case handHeart = "双手比心"
    case thumbsUp = "点赞"
    case maracas = "摇沙锤"

    var id: Self { self }

    var depictsSystemState: Bool {
        switch self {
        case .charging, .charged, .listening, .thinking: true
        default: false
        }
    }

    var hasVariants: Bool {
        switch self {
        case .idle, .charging, .charged: false
        default: true
        }
    }

    var previewDuration: TimeInterval {
        hasVariants ? motionDuration * Double(PetExpressionVariant.allCases.count) : 15
    }

    // The original timing of one pass through the choreography.
    var motionDuration: TimeInterval {
        switch self {
        case .celebrate: 1.42
        case .angry: 1.22
        case .delighted: 1.50
        case .cool: 2.15
        case .idle: 12
        case .happy: 1.9
        case .proud: 2.8
        case .sad: 3.5
        case .crying: 3.8
        case .surprised: 2.3
        case .curious: 3.2
        case .affectionate: 2.5
        case .sleepy: 3.4
        case .dizzy: 2.6
        case .musical: 3.1
        case .greeting: 2.1
        case .shy: 2.7
        case .laughing: 2.5
        case .winking: 1.8
        case .listening: 3.0
        case .thinking: 2.8
        case .confused: 2.3
        case .peeking: 2.6
        case .yawning: 2.7
        case .kiss: 2.3
        case .hungry: 2.5
        case .munching: 2.8
        case .bubbles: 2.8
        case .freezing: 2.6
        case .dancing: 3.0
        case .charging: 3.8
        case .charged: 2.4
        case .handHeart: 2.5
        case .thumbsUp: 2.2
        case .maracas: 3.0
        }
    }

    private func motionTime(at elapsed: TimeInterval, playbackDuration: TimeInterval?) -> TimeInterval {
        guard self != .idle, let playbackDuration, playbackDuration != motionDuration else { return elapsed }
        let passes = (playbackDuration / motionDuration).rounded()
        return elapsed * (passes * motionDuration / playbackDuration)
    }

    func effectElapsed(at elapsed: TimeInterval, playbackDuration: TimeInterval?) -> TimeInterval {
        let time = motionTime(at: elapsed, playbackDuration: playbackDuration)
        // The charging cable connects once while its current keeps flowing.
        if self == .idle || self == .charging { return time }
        return time.truncatingRemainder(dividingBy: motionDuration)
    }

    var symbol: String {
        switch self {
        case .idle: "eye"
        case .happy: "face.smiling"
        case .angry: "bolt"
        case .proud: "sparkle"
        case .sad: "cloud"
        case .crying: "drop"
        case .surprised: "exclamationmark.circle"
        case .curious: "questionmark.circle"
        case .celebrate: "party.popper"
        case .delighted: "star.fill"
        case .cool: "sunglasses"
        case .affectionate: "heart.fill"
        case .sleepy: "moon.zzz.fill"
        case .dizzy: "wind"
        case .musical: "music.note"
        case .greeting: "hand.wave"
        case .shy: "face.smiling.inverse"
        case .laughing: "face.smiling.fill"
        case .winking: "eye.fill"
        case .listening: "ear"
        case .thinking: "ellipsis.bubble"
        case .confused: "questionmark"
        case .peeking: "binoculars"
        case .yawning: "moon.stars"
        case .kiss: "heart.circle"
        case .hungry: "fork.knife"
        case .munching: "carrot"
        case .bubbles: "bubbles.and.sparkles"
        case .freezing: "snowflake"
        case .dancing: "music.note.list"
        case .charging: "battery.50percent.bolt"
        case .charged: "battery.100percent"
        case .handHeart: "heart.fill"
        case .thumbsUp: "hand.thumbsup.fill"
        case .maracas: "music.note"
        }
    }

    static let quickExpressions: [Self] = [.happy, .winking, .affectionate, .delighted, .cool, .sleepy]

    static let groups: [(title: String, expressions: [Self])] = [
        ("日常心情", [.idle, .happy, .laughing, .angry, .proud, .sad, .crying, .surprised, .curious, .shy]),
        ("互动小动作", [.greeting, .winking, .peeking, .listening, .thinking, .confused, .kiss, .affectionate, .handHeart, .thumbsUp, .hungry, .munching]),
        ("趣味彩蛋", [.celebrate, .delighted, .cool, .sleepy, .yawning, .dizzy, .musical, .bubbles, .freezing, .dancing, .maracas, .charging, .charged])
    ]

    var pose: PetPose {
        switch self {
        case .idle:
            PetPose(left: EyePose(), right: EyePose())
        case .happy:
            PetPose(left: EyePose(width: 1.35, height: 0.17, curve: -25, lift: -2, lidWeight: 13.2),
                    right: EyePose(width: 1.35, height: 0.17, curve: -25, lift: -2, lidWeight: 13.2),
                    mouth: 0.9, mouthCurve: 0.85, cheeks: 0.68)
        case .angry:
            PetPose(left: EyePose(width: 1.06, height: 0.54, tilt: 0.25),
                    right: EyePose(width: 1.06, height: 0.54, tilt: -0.25),
                    anger: 0.82)
        case .proud:
            PetPose(left: EyePose(height: 0.41, tilt: -0.13, curve: -35, lift: 7),
                    right: EyePose(height: 0.86, tilt: -0.05, lift: -7),
                    mouth: 0.9, mouthCurve: 0.43, smirk: 0.85, cheeks: 0.28)
        case .sad:
            PetPose(left: EyePose(width: 1.03, height: 0.16, tilt: 0.15, curve: 29, lift: 5, lidWeight: 13.2),
                    right: EyePose(width: 1.03, height: 0.16, tilt: -0.15, curve: 29, lift: 5, lidWeight: 13.2),
                    brightness: 0.9, mouth: 0.7, mouthCurve: -0.52, lookY: 9)
        case .crying:
            PetPose(left: EyePose(height: 0.17, tilt: -0.22, curve: 65, lift: 10, lidWeight: 13.2),
                    right: EyePose(height: 0.17, tilt: 0.22, curve: 65, lift: 10, lidWeight: 13.2),
                    brightness: 0.85, mouth: 0.9, mouthCurve: -0.7, tears: 1, lookY: 6)
        case .surprised:
            PetPose(left: EyePose(width: 0.80, height: 1.21, lift: -7),
                    right: EyePose(width: 0.80, height: 1.21, lift: -7),
                    mouth: 0.9, mouthOpen: 0.79, mouthRound: 0.96)
        case .curious:
            PetPose(left: EyePose(height: 0.81, tilt: 0.10, lift: 4),
                    right: EyePose(height: 1.08, tilt: 0.12, lift: -7),
                    mouth: 0.55, mouthCurve: 0.32, lookX: 16, lookY: -4)
        case .celebrate:
            PetPose(left: EyePose(), right: EyePose(), confetti: 1)
        case .delighted:
            PetPose(left: EyePose(), right: EyePose(), stars: 1)
        case .cool:
            PetPose(left: EyePose(), right: EyePose(), glasses: 1)
        case .affectionate:
            PetPose(left: EyePose(), right: EyePose(), cheeks: 0.8, hearts: 1)
        case .sleepy:
            PetPose(left: EyePose(width: 0.98, height: 0.11, curve: 36, lidWeight: 10),
                    right: EyePose(width: 0.98, height: 0.11, curve: 36, lidWeight: 10),
                    brightness: 0.61, lookY: 8, sleep: 1)
        case .dizzy:
            PetPose(left: EyePose(), right: EyePose(), spirals: 1)
        case .greeting:
            PetPose(left: EyePose(height: 0.92), right: EyePose(height: 0.92),
                    mouth: 0.68, mouthCurve: 0.9, cheeks: 0.22, greeting: 1)
        case .shy:
            PetPose(left: EyePose(height: 0.54, tilt: -0.13, curve: -19),
                    right: EyePose(height: 0.64, tilt: -0.10, curve: -11),
                    brightness: 0.88, mouth: 0.62, mouthCurve: 0.58,
                    lookX: -13, lookY: 10, cheeks: 0.94)
        case .laughing:
            PetPose(left: EyePose(width: 1.12, height: 0.19, curve: -99, lidWeight: 11.4),
                    right: EyePose(width: 1.12, height: 0.19, curve: -99, lidWeight: 11.4),
                    mouth: 1, mouthCurve: 0.93, mouthOpen: 0.94, mouthTongue: 0.94, cheeks: 0.82, accent: .laugh)
        case .winking:
            PetPose(left: EyePose(width: 1.03, height: 0.14, curve: -24, lidWeight: 9.6),
                    right: EyePose(height: 0.91, lift: -5),
                    mouth: 0.88, mouthCurve: 0.8, cheeks: 0.56, accent: .wink)
        case .listening:
            PetPose(left: EyePose(width: 1.34, height: 1.12, lift: -7),
                    right: EyePose(width: 1.34, height: 1.12, lift: -7),
                    lookY: -6, accent: .listen)
        case .thinking:
            PetPose(left: EyePose(height: 0.61, lift: 2), right: EyePose(height: 0.86, lift: -8),
                    mouth: 0.55, mouthCurve: -0.23, lookX: 13, lookY: -10, accent: .thought)
        case .confused:
            PetPose(left: EyePose(height: 1.06, tilt: -0.18, lift: -9),
                    right: EyePose(height: 0.46, tilt: -0.26, lift: 8),
                    mouth: 0.7, mouthCurve: -0.38, smirk: 0.55, lookX: -10, accent: .question)
        case .peeking:
            PetPose(left: EyePose(height: 0.84), right: EyePose(height: 1.04, lift: -5),
                    lookX: -72, lookY: 27, accent: .peek)
        case .yawning:
            PetPose(left: EyePose(height: 0.17, curve: 85, lidWeight: 12),
                    right: EyePose(height: 0.17, curve: 85, lidWeight: 12),
                    mouth: 1, mouthOpen: 1, mouthRound: 1, mouthTongue: 0.25, lookY: 1, accent: .yawn)
        case .kiss:
            PetPose(left: EyePose(height: 0.20, curve: -75, lidWeight: 10.5),
                    right: EyePose(height: 0.20, curve: -75, lidWeight: 10.5),
                    mouth: 0.83, mouthOpen: 0.43, mouthRound: 0.82, cheeks: 0.92, accent: .kiss)
        case .hungry:
            PetPose(left: EyePose(width: 0.91, height: 1.14), right: EyePose(width: 0.91, height: 1.14),
                    mouth: 0.85, mouthOpen: 0.48, mouthRound: 0.86, lookX: 13, accent: .hungry)
        case .munching:
            PetPose(left: EyePose(height: 0.28, curve: -75, lidWeight: 11.6),
                    right: EyePose(height: 0.28, curve: -75, lidWeight: 11.6),
                    mouth: 0.9, mouthCurve: 0.58, mouthOpen: 0.44, mouthTongue: 0.46, cheeks: 0.64, accent: .crumbs)
        case .bubbles:
            PetPose(left: EyePose(height: 0.78), right: EyePose(height: 0.88, lift: -3),
                    mouth: 0.95, mouthOpen: 0.55, mouthRound: 1, lookX: -7, accent: .bubbles)
        case .freezing:
            PetPose(left: EyePose(width: 0.94, height: 0.24, tilt: -0.09),
                    right: EyePose(width: 0.94, height: 0.24, tilt: 0.09),
                    brightness: 0.82, mouth: 0.8, mouthCurve: -0.54, accent: .frost)
        case .dancing:
            PetPose(left: EyePose(height: 0.24, curve: -80, lidWeight: 10.5), right: EyePose(height: 0.62, lift: -7),
                    mouth: 0.86, mouthCurve: 0.84, cheeks: 0.38, accent: .dance)
        case .handHeart:
            PetPose(left: EyePose(height: 0.22, curve: -80, lift: -12, lidWeight: 11),
                    right: EyePose(height: 0.22, curve: -80, lift: -12, lidWeight: 11),
                    cheeks: 0.70, accent: .handHeart)
        case .thumbsUp:
            PetPose(left: EyePose(height: 0.25, curve: -82, lift: -10, lidWeight: 11),
                    right: EyePose(height: 0.30, curve: -76, lift: -10, lidWeight: 11),
                    mouth: 0.85, mouthCurve: 0.9, cheeks: 0.36, accent: .thumbsUp)
        case .maracas:
            PetPose(left: EyePose(height: 0.29, curve: -75, lift: -12, lidWeight: 11),
                    right: EyePose(height: 0.29, curve: -75, lift: -12, lidWeight: 11),
                    mouth: 0.75, mouthCurve: 0.71, mouthOpen: 0.55, mouthTongue: 0.35, cheeks: 0.48, accent: .maracas)
        case .charging:
            PetPose(left: EyePose(height: 0.73, lift: -18),
                    right: EyePose(height: 0.73, lift: -18),
                    lookX: 6, accent: .charging)
        case .charged:
            PetPose(left: EyePose(), right: EyePose(), accent: .power)
        case .musical:
            PetPose(left: EyePose(height: 0.22, curve: -80, lidWeight: 11),
                    right: EyePose(height: 0.22, curve: -80, lidWeight: 11),
                    mouth: 0.74, mouthCurve: 0.52, mouthOpen: 0.48, mouthRound: 0.25, cheeks: 0.40, notes: 1)
        }
    }
}

struct EyePose {
    var width: CGFloat = 1
    var height: CGFloat = 1
    var tilt: CGFloat = 0
    var curve: CGFloat = 0
    var lift: CGFloat = 0
    var lidWeight: CGFloat = 6.8
    var shift: CGFloat = 0

    func blended(with end: Self, progress: CGFloat) -> Self {
        Self(width: mix(width, end.width, progress),
             height: mix(height, end.height, progress),
             tilt: mix(tilt, end.tilt, progress),
             curve: mix(curve, end.curve, progress),
             lift: mix(lift, end.lift, progress),
             lidWeight: mix(lidWeight, end.lidWeight, progress),
             shift: mix(shift, end.shift, progress))
    }
}

enum PetAccent: Equatable {
    case none, laugh, wink, thought, question, peek, yawn, kiss, hungry, crumbs, bubbles, frost, dance, charging, power, handHeart, thumbsUp, maracas
    case listen, marchGuitar
}

struct PetPose {
    // The ES8 recording's kick repeats about 162.5 times per minute.
    static func marchBeat(at elapsed: TimeInterval) -> Double {
        max(0, (elapsed - 0.04) / 0.3693)
    }

    var left: EyePose
    var right: EyePose
    var brightness: CGFloat = 1
    var mouth: CGFloat = 0
    var mouthCurve: CGFloat = 0
    var smirk: CGFloat = 0
    var tears: CGFloat = 0
    var mouthOpen: CGFloat = 0
    var mouthRound: CGFloat = 0
    var mouthTongue: CGFloat = 0
    var lookX: CGFloat = 0
    var lookY: CGFloat = 0
    var bounce: CGFloat = 0
    var cheeks: CGFloat = 0
    var anger: CGFloat = 0
    var confetti: CGFloat = 0
    var stars: CGFloat = 0
    var glasses: CGFloat = 0
    var hearts: CGFloat = 0
    var sleep: CGFloat = 0
    var spirals: CGFloat = 0
    var notes: CGFloat = 0
    var greeting: CGFloat = 0
    var turn: CGFloat = 0
    var accent: PetAccent = .none
    var accentOpacity: CGFloat = 1

    static var pettingSmile: Self {
        var pose = PetExpression.happy.pose
        pose.left.height = 0.22
        pose.right.height = 0.22
        pose.cheeks = 0.95
        return pose
    }

    func blended(with end: Self, progress: CGFloat) -> Self {
        if progress <= 0 { return self }
        if progress >= 1 { return end }
        let sameAccent = accent == end.accent
        let keepCurrent = end.accent == .none || (accent != .none && progress < 0.5)
        let transition = accent == .none || end.accent == .none ? progress : min(1, abs(progress - 0.5) * 2)
        let opacity = sameAccent ? mix(accentOpacity, end.accentOpacity, progress)
            : (keepCurrent ? accentOpacity * (end.accent == .none ? 1 - progress : transition)
                           : end.accentOpacity * transition)
        return Self(left: left.blended(with: end.left, progress: progress),
             right: right.blended(with: end.right, progress: progress),
             brightness: mix(brightness, end.brightness, progress),
             mouth: mix(mouth, end.mouth, progress),
             mouthCurve: mix(mouthCurve, end.mouthCurve, progress),
             smirk: mix(smirk, end.smirk, progress),
             tears: mix(tears, end.tears, progress),
             mouthOpen: mix(mouthOpen, end.mouthOpen, progress),
             mouthRound: mix(mouthRound, end.mouthRound, progress),
             mouthTongue: mix(mouthTongue, end.mouthTongue, progress),
             lookX: mix(lookX, end.lookX, progress),
             lookY: mix(lookY, end.lookY, progress),
             bounce: mix(bounce, end.bounce, progress),
             cheeks: mix(cheeks, end.cheeks, progress),
             anger: mix(anger, end.anger, progress),
             confetti: mix(confetti, end.confetti, progress),
             stars: mix(stars, end.stars, progress),
             glasses: mix(glasses, end.glasses, progress),
             hearts: mix(hearts, end.hearts, progress),
             sleep: mix(sleep, end.sleep, progress),
             spirals: mix(spirals, end.spirals, progress),
             notes: mix(notes, end.notes, progress),
             greeting: mix(greeting, end.greeting, progress),
             turn: mix(turn, end.turn, progress),
             accent: sameAccent || keepCurrent ? accent : end.accent,
             accentOpacity: opacity)
    }
}

enum PetExpressionShow: String, CaseIterable, Identifiable {
    case party, theater, all

    var id: Self { self }

    var title: String {
        switch self {
        case .party: "元气派对"
        case .theater: "反差小剧场"
        case .all: "看全部"
        }
    }

    var expressions: [PetExpression] {
        switch self {
        case .party: [.greeting, .delighted, .cool, .bubbles, .maracas, .dancing, .celebrate]
        case .theater: [.peeking, .curious, .confused, .surprised, .dizzy, .shy, .laughing, .kiss]
        case .all: PetExpression.groups.flatMap(\.expressions)
        }
    }

    var pauseBetweenSteps: TimeInterval { self == .all ? 0.55 : 2.3 }

    var estimatedSeconds: Int {
        let moves = expressions.reduce(0) { $0 + $1.motionDuration }
        let pauses = Double(max(0, expressions.count - 1)) * pauseBetweenSteps
        return Int((moves + pauses).rounded())
    }
}

struct PetRotationRound: Codable {
    private(set) var remaining: [PetExpression]
    private(set) var variant: PetExpressionVariant
    private(set) var lastCompleted: PetExpression?

    private static let intense: Set<PetExpression> = [.angry, .sad, .crying]
    private static let light: Set<PetExpression> = [.happy, .laughing, .winking, .greeting, .affectionate, .peeking, .yawning]
    private static let lively: Set<PetExpression> = [.greeting, .celebrate, .delighted, .bubbles, .dancing, .handHeart, .maracas]

    init() {
        remaining = Self.order(after: nil)
        variant = .original
    }

    var nextExpression: PetExpression { remaining[0] }

    mutating func complete(_ expression: PetExpression) {
        guard expression == nextExpression else { return }
        remaining.removeFirst()
        lastCompleted = expression
        if remaining.isEmpty {
            remaining = Self.order(after: lastCompleted)
            variant = variant.next
        }
    }

    static func restored(from data: Data?) -> Self {
        guard let data, let round = try? JSONDecoder().decode(Self.self, from: data),
              !round.remaining.isEmpty, Set(round.remaining).count == round.remaining.count else { return Self() }
        return round
    }

    private static func order(after last: PetExpression?) -> [PetExpression] {
        let all = PetExpression.allCases
        var ordinary = all.filter { !intense.contains($0) }.shuffled()
        var dramatic = all.filter { intense.contains($0) }.shuffled()
        var result: [PetExpression] = []

        for _ in 0..<3 {
            if let index = ordinary.firstIndex(where: { $0 != last && lively.contains($0) }) {
                result.append(ordinary.remove(at: index))
            }
        }

        // Space the three dramatic actions across the round and follow each with a lighter beat.
        var lighterBeats: [PetExpression] = []
        for _ in dramatic {
            if let index = ordinary.firstIndex(where: light.contains) {
                lighterBeats.append(ordinary.remove(at: index))
            }
        }
        let checkpoints = [5...9, 13...18, 22...28].map { Int.random(in: $0) }
        for index in checkpoints {
            while result.count < index { result.append(ordinary.removeFirst()) }
            result.append(dramatic.removeFirst())
            result.append(lighterBeats.removeFirst())
        }
        result.append(contentsOf: ordinary)
        return result
    }
}

struct PetPlayback {
    private(set) var baseline = PetExpression.idle
    private var baselineStart: TimeInterval = 0
    private var baselineMotionStart: TimeInterval?
    private var baselineFrom: PetPose?
    private var baselineScaleFrom: CGFloat?
    struct GlowLayer {
        let expression: PetExpression
        let startedAt: TimeInterval
        var opacity: Double
        var variant: PetExpressionVariant = .original
        var isBaseline = false
        var duration: TimeInterval? = nil
        var exitPose: PetPose? = nil
        var exitElapsed: TimeInterval? = nil
    }

    private var baselineGlow: [GlowLayer] = []
    private var selected: PetExpression?
    private var selectedVariant: PetExpressionVariant = .original
    private var nextVariant: [PetExpression: PetExpressionVariant] = [:]
    private var selectionKind = SelectionKind.reaction
    private var selectionDurationOverride: TimeInterval?
    private var startPose = PetExpression.idle.pose
    private var startScale: CGFloat = 1
    private var startTime: TimeInterval = 0
    private var tapLook = CGPoint.zero
    private var previousGlow: [GlowLayer] = []
    static let tapBurstRelease: TimeInterval = 0.42

    private var lastTap: TimeInterval?
    private var tapCount = 0
    private var userUntil: TimeInterval = 0
    private var lastReaction: TimeInterval = -.infinity
    private var usesFreezingProps = true

    mutating func respondToTap(at time: TimeInterval, toward point: CGPoint = .zero) -> PetExpression {
        if isTapBurst(at: time) { return .angry }
        let continues = lastTap.map { time - $0 <= 1 } == true
        tapCount = continues ? tapCount + 1 : 1
        lastTap = time

        if tapCount == 8 {
            start(.angry, at: time, kind: .tapBurst, duration: 1.85)
            userUntil = time + selectionDuration
            resetTapSequence()
            return .angry
        }
        // Keep counting without restarting the angry animation on every poke.
        if tapCount > 3, expression(at: time) == .angry { return .angry }

        let expression: PetExpression = switch tapCount {
        case 1: .happy
        case 2: .surprised
        default: .angry
        }
        start(expression, at: time, toward: point, kind: tapCount == 1 ? .tapSmile : .reaction,
              duration: tapCount == 1 ? 0.94 : nil)
        userUntil = time + selectionDuration
        return expression
    }

    mutating func resetTapSequence() {
        tapCount = 0
        lastTap = nil
    }

    mutating func playTapSmile(at time: TimeInterval, toward point: CGPoint) {
        start(.happy, at: time, toward: point, kind: .tapSmile, duration: 0.94)
        userUntil = time + selectionDuration
    }

    mutating func show(_ expression: PetExpression, at time: TimeInterval, toward point: CGPoint = .zero) {
        start(expression, at: time, toward: point, kind: .preview)
        userUntil = time + expression.previewDuration
        resetTapSequence()
    }

    @discardableResult
    mutating func react(_ expression: PetExpression, at time: TimeInterval, priority: ReactionPriority = .normal,
                        usesFreezingProps: Bool = true) -> Bool {
        switch priority {
        case .normal:
            guard time >= userUntil, time - lastReaction >= 1.5,
                  activeSelection(at: time) == nil || selectionKind == .ambient || selectionKind == .rotation else { return false }
        case .immediate:
            break
        }
        start(expression, at: time)
        self.usesFreezingProps = usesFreezingProps
        lastReaction = time
        return true
    }

    enum ReactionPriority { case normal, immediate }

    private enum SelectionKind {
        case reaction, preview, ambient, chargeCompletion, rotation, show, march, petting, tapSmile, quickBrowse, tapBurst
    }

    func isTapBurst(at time: TimeInterval) -> Bool {
        selectionKind == .tapBurst && hasActiveSelection(at: time)
    }

    mutating func playQuickExpression(_ expression: PetExpression, at time: TimeInterval) {
        start(expression, at: time, kind: .quickBrowse)
        userUntil = time + selectionDuration
    }

    func isBrowsing(at time: TimeInterval) -> Bool {
        selectionKind == .quickBrowse && activeSelection(at: time) != nil
    }

    mutating func playAmbient(_ expression: PetExpression, at time: TimeInterval) {
        start(expression, at: time, kind: .ambient)
    }

    mutating func playChargeCompletion(at time: TimeInterval) {
        start(.charged, at: time, kind: .chargeCompletion)
    }

    mutating func playPettingSmile(at time: TimeInterval, startingAt pose: PetPose) {
        start(.happy, at: time, kind: .petting)
        startPose = pose
        userUntil = time + selectionDuration
    }

    mutating func playRotation(_ expression: PetExpression, variant: PetExpressionVariant, at time: TimeInterval) {
        start(expression, at: time, kind: .rotation, variant: variant)
    }

    mutating func takeCompletedRotation(at time: TimeInterval) -> PetExpression? {
        guard selectionKind == .rotation, !hasActiveSelection(at: time) else { return nil }
        selectionKind = .reaction
        return selected
    }

    mutating func playShowStep(_ expression: PetExpression, at time: TimeInterval) {
        start(expression, at: time, kind: .show)
    }

    mutating func playMarch(duration: TimeInterval, at time: TimeInterval) {
        start(.musical, at: time, kind: .march, duration: duration)
    }

    func activeExpressionPass(at time: TimeInterval) -> (expression: PetExpression, startedAt: TimeInterval)? {
        guard let selected = activeSelection(at: time) else { return nil }
        return (selected, pass(for: selected, at: time).startedAt)
    }

    func isPreviewing(at time: TimeInterval) -> Bool {
        selectionKind == .preview && hasActiveSelection(at: time)
    }

    func isPlayingAmbient(at time: TimeInterval) -> Bool {
        selectionKind == .ambient && hasActiveSelection(at: time)
    }

    func isPlayingRotation(at time: TimeInterval) -> Bool {
        selectionKind == .rotation && hasActiveSelection(at: time)
    }

    func isPlayingChargeCompletion(at time: TimeInterval) -> Bool {
        selectionKind == .chargeCompletion && hasActiveSelection(at: time)
    }

    func hasActiveSelection(at time: TimeInterval) -> Bool { activeSelection(at: time) != nil }

    mutating func setBaseline(_ expression: PetExpression, at time: TimeInterval,
                              motionStartedAt: TimeInterval? = nil, interrupt: Bool = false) {
        guard expression != baseline || motionStartedAt != baselineMotionStart || interrupt else { return }
        let blend = interrupt || activeSelection(at: time) == nil
        baselineFrom = blend ? pose(at: time) : nil
        baselineScaleFrom = blend ? faceScale(at: time) : nil
        baselineGlow = baselineFrom.map { outgoingGlow(at: time, pose: $0) } ?? []
        if interrupt {
            selected = nil
            selectionKind = .reaction
            selectionDurationOverride = nil
            userUntil = time
        }
        baselineStart = time
        baselineMotionStart = motionStartedAt
        baseline = expression
    }

    private mutating func start(_ expression: PetExpression, at time: TimeInterval, toward point: CGPoint = .zero,
                                kind: SelectionKind = .reaction, variant: PetExpressionVariant? = nil,
                                duration: TimeInterval? = nil) {
        startPose = pose(at: time)
        startScale = faceScale(at: time)
        previousGlow = outgoingGlow(at: time, pose: startPose)
        baselineFrom = nil
        baselineScaleFrom = nil
        baselineGlow = []
        startTime = time
        selected = expression
        selectionKind = kind
        selectionDurationOverride = duration
        if expression.hasVariants && (kind == .reaction || kind == .ambient) {
            selectedVariant = nextVariant[expression, default: .original]
            nextVariant[expression] = selectedVariant.next
        } else {
            selectedVariant = expression.hasVariants ? variant ?? .original : .original
        }
        tapLook = point
        usesFreezingProps = true
    }

    func expression(at time: TimeInterval) -> PetExpression {
        activeSelection(at: time) ?? baseline
    }

    func variant(at time: TimeInterval) -> PetExpressionVariant {
        guard let selected = activeSelection(at: time) else { return .original }
        return pass(for: selected, at: time).variant
    }

    func stillPose(at time: TimeInterval) -> PetPose {
        if isTapBurst(at: time) {
            return tapBurstPose(at: elapsed(at: time), motionEnabled: false)
        }
        return expression(at: time).stillPose(for: variant(at: time))
    }

    func elapsed(at time: TimeInterval) -> TimeInterval {
        if activeSelection(at: time) != nil { return max(0, time - startTime) }
        let age = baselineAge(at: time)
        if baseline == .idle || baseline == .charging { return age }
        return age.truncatingRemainder(dividingBy: baseline.motionDuration)
    }

    func effectElapsed(at time: TimeInterval) -> TimeInterval {
        guard let selected = activeSelection(at: time) else { return elapsed(at: time) }
        let pass = pass(for: selected, at: time)
        return selected.effectElapsed(at: max(0, time - pass.startedAt), playbackDuration: pass.duration)
    }

    func faceScale(at time: TimeInterval) -> CGFloat {
        let resting = Self.expressionScale(baseline)
        guard let selected = activeSelection(at: time) else {
            guard let baselineScaleFrom else { return resting }
            return mix(baselineScaleFrom, resting, eased((time - baselineStart) / 0.24))
        }
        let age = max(0, time - startTime)
        let entrance = eased(age / 0.24)
        let exit = eased((selectionDuration - age) / 0.26)
        return mix(resting, mix(startScale, Self.expressionScale(selected), entrance), exit)
    }

    private static func expressionScale(_ expression: PetExpression) -> CGFloat {
        switch expression {
        case .idle, .sleepy: 1
        case .happy, .laughing, .surprised: 1.25
        default: 1.17
        }
    }

    func glow(at time: TimeInterval) -> [GlowLayer] {
        var resting = GlowLayer(expression: baseline, startedAt: time - baselineGlowAge(at: time),
                                opacity: 1, isBaseline: true)
        guard let selected = activeSelection(at: time) else {
            let blend = Double(eased((time - baselineStart) / 0.24))
            if baselineGlow.isEmpty || blend >= 1 { return [resting] }
            let outgoing = fadedGlow(baselineGlow, by: 1 - blend)
            resting.opacity = blend
            return outgoing + [resting]
        }
        let elapsed = max(0, time - startTime)
        let transition = entranceDuration
        let entrance = previousGlow.isEmpty ? 1 : Double(eased(elapsed / transition))
        var layers = fadedGlow(previousGlow, by: 1 - entrance)
        let exit = Double(eased((selectionDuration - elapsed) / 0.26))
        if exit < 1 {
            resting.opacity = 1 - exit
            layers.append(resting)
        }
        let pass = pass(for: selected, at: time)
        layers.append(GlowLayer(expression: selected, startedAt: pass.startedAt, opacity: entrance * exit,
                                variant: pass.variant, duration: pass.duration))
        return layers
    }

    private func fadedGlow(_ layers: [GlowLayer], by amount: Double) -> [GlowLayer] {
        layers.compactMap { layer in
            let opacity = layer.opacity * amount
            guard opacity > 0.02 else { return nil }
            var faded = layer
            faded.opacity = opacity
            return faded
        }
    }

    private func outgoingGlow(at time: TimeInterval, pose: PetPose) -> [GlowLayer] {
        glow(at: time).compactMap { layer in
            guard layer.opacity > 0.02 else { return nil }
            var outgoing = layer
            outgoing.exitPose = layer.exitPose ?? pose
            outgoing.exitElapsed = layer.exitElapsed ?? (time - layer.startedAt)
            return outgoing
        }
    }

    func pose(at time: TimeInterval) -> PetPose {
        let resting = baseline.poseWithTurn(at: baselineAge(at: time), toward: .zero, isBaseline: true)
        guard let selected = activeSelection(at: time) else {
            if let baselineFrom {
                return baselineFrom.blended(with: resting, progress: eased((time - baselineStart) / 0.24))
            }
            return resting
        }
        let pass = pass(for: selected, at: time)
        let elapsed = max(0, time - pass.startedAt)
        let duration = pass.duration
        // Even the idle animation can end on a blink when its preview is interrupted.
        if selected != .idle || baseline != .idle || selectionKind == .preview {
            let settle = min(0.24, duration * 0.16)
            let settleStart = duration - settle
            if elapsed > settleStart {
                let destination = if pass.variant != .third && isRotatingPreview(selected) {
                    PetExpression.idle.pose
                } else {
                    baseline.poseWithTurn(at: baselineAge(at: pass.startedAt + duration),
                                          toward: .zero, isBaseline: true)
                }
                return selectedPose(selected, pass: pass, at: settleStart).blended(
                    with: destination,
                    progress: eased((elapsed - settleStart) / settle)
                )
            }
        }

        let target = selectedPose(selected, pass: pass, at: elapsed)
        return startPose.blended(with: target, progress: eased((time - startTime) / entranceDuration))
    }

    private var entranceDuration: TimeInterval {
        switch selectionKind {
        case .tapSmile, .tapBurst, .petting: 0.10
        default: 0.16
        }
    }

    private func selectedPose(_ expression: PetExpression, pass: Pass, at elapsed: TimeInterval) -> PetPose {
        if selectionKind == .tapBurst {
            return tapBurstPose(at: elapsed, motionEnabled: true)
        }
        if selectionKind == .tapSmile {
            var pose = PetExpression.idle.pose.blended(with: expression.pose, progress: eased((elapsed - 0.19) / 0.22))
            let gaze = 1 - eased((elapsed - 0.40) / 0.30)
            pose.lookX = tapLook.x * gaze
            pose.lookY = tapLook.y * gaze
            pose.turn = max(-0.55, min(0.55, pose.lookX / 45))
            return pose
        }
        var pose = expression.poseWithTurn(at: elapsed, toward: tapLook, playbackDuration: pass.duration,
                                           variant: pass.variant)
        if expression == .freezing && !usesFreezingProps { pose.accent = .none }
        return pose
    }

    private func tapBurstPose(at age: TimeInterval, motionEnabled: Bool) -> PetPose {
        let puffLeft = EyePose(width: 1.12, height: 0.25, tilt: 0.27, lift: 7, lidWeight: 12)
        let puffRight = EyePose(width: 1.12, height: 0.25, tilt: -0.27, lift: 7, lidWeight: 12)
        let puff = PetPose(left: puffLeft, right: puffRight, mouth: 1, mouthCurve: -0.7,
                           lookY: 5, cheeks: 1, anger: 1)
        let wideEyes = EyePose(width: 0.85, height: 1.38, lift: -8)
        let burst = PetPose(left: wideEyes, right: wideEyes, mouth: 1, mouthOpen: 1,
                            mouthRound: 1, bounce: motionEnabled ? -12 : 0, cheeks: 0.64, anger: 0.72)
        let tiredEyes = EyePose(width: 1.05, height: 0.22, curve: 31, lift: 9, lidWeight: 10)
        let tired = PetPose(left: tiredEyes, right: tiredEyes, brightness: 0.80, mouth: 1,
                            mouthOpen: 0.48, mouthRound: 0.68, lookY: 7, cheeks: 0.26, anger: 0.08)
        let release = Self.tapBurstRelease
        switch age {
        case ..<release:
            var pose = PetExpression.angry.pose.blended(with: puff, progress: eased(age / 0.3))
            if motionEnabled {
                let shake = eased(age / 0.14) * (1 - eased((age - 0.30) / (release - 0.30)))
                pose.lookX = sin(age * 46) * 4 * shake
            }
            return pose
        case ..<0.59:
            return puff.blended(with: burst, progress: eased((age - release) / 0.12))
        case ..<0.94:
            return burst.blended(with: tired, progress: eased((age - 0.59) / 0.35))
        default:
            return tired.blended(with: PetExpression.idle.pose, progress: eased((age - 1.05) / 0.56))
        }
    }

    private struct Pass {
        let variant: PetExpressionVariant
        let startedAt: TimeInterval
        let duration: TimeInterval
    }

    private func isRotatingPreview(_ expression: PetExpression) -> Bool {
        selectionKind == .preview && expression.hasVariants
    }

    private func pass(for expression: PetExpression, at time: TimeInterval) -> Pass {
        guard isRotatingPreview(expression) else {
            return Pass(variant: selectedVariant, startedAt: startTime, duration: selectionDuration)
        }
        let duration = expression.motionDuration
        let variant = PetExpressionVariant.allCases.last { time >= startTime + Double($0.rawValue) * duration } ?? .original
        return Pass(variant: variant, startedAt: startTime + Double(variant.rawValue) * duration, duration: duration)
    }

    private var selectionDuration: TimeInterval {
        guard let selected else { return 0 }
        if let selectionDurationOverride { return selectionDurationOverride }
        return selectionKind == .preview ? selected.previewDuration : selected.motionDuration
    }

    private var selectionEnd: TimeInterval? { selected.map { _ in startTime + selectionDuration } }

    private func activeSelection(at time: TimeInterval) -> PetExpression? {
        time < (selectionEnd ?? 0) ? selected : nil
    }

    private func baselineAge(at time: TimeInterval) -> TimeInterval {
        max(0, time - (baselineMotionStart ?? max(baselineStart, selectionEnd ?? 0)))
    }

    private func baselineGlowAge(at time: TimeInterval) -> TimeInterval {
        let age = baselineAge(at: time)
        if baseline == .idle || baseline == .charging { return age }
        return age.truncatingRemainder(dividingBy: baseline.motionDuration)
    }
}

extension PetExpression {
    private struct Beat {
        let time: TimeInterval
        let pose: PetPose

        init(time: TimeInterval, pose: PetPose, _ change: (inout PetPose) -> Void = { _ in }) {
            self.time = time
            var pose = pose
            change(&pose)
            self.pose = pose
        }
    }

    func stillPose(for variant: PetExpressionVariant) -> PetPose {
        guard hasVariants, variant != .original else { return pose }
        if self == .happy { return happySmile(for: variant) }
        var result = pose
        switch variant {
        case .original:
            break
        case .second:
            result.left.width *= 1.10
            result.right.width *= 1.10
            result.left.height *= 0.9
            result.right.height *= 0.9
        case .third:
            result.left.lift += 3 * leanDirection
            result.right.lift -= 3 * leanDirection
        }
        return result
    }

    fileprivate func poseWithTurn(at elapsed: TimeInterval, toward tap: CGPoint, isBaseline: Bool = false,
                                  playbackDuration: TimeInterval? = nil,
                                  variant: PetExpressionVariant = .original) -> PetPose {
        var result = animatedPose(at: elapsed, isBaseline: isBaseline,
                                  playbackDuration: playbackDuration, variant: variant)
        let attention = 1 - eased((elapsed - 0.16) / 0.55)
        result.lookX += tap.x * attention
        result.lookY += tap.y * attention
        // The eye shift leads the turn by about three frames.
        let delayed = max(0, elapsed - 0.10)
        let delayedAttention = eased(delayed / 0.12) * (1 - eased((delayed - 0.16) / 0.55))
        let direction = animatedPose(at: delayed, isBaseline: isBaseline,
                                     playbackDuration: playbackDuration, variant: variant).lookX
            + tap.x * delayedAttention
        result.turn = min(1, max(-1, direction / 28))
        return result
    }

    private func animatedPose(at elapsed: TimeInterval, isBaseline: Bool, playbackDuration: TimeInterval?,
                              variant: PetExpressionVariant) -> PetPose {
        let alternate = hasVariants && variant != .original && !isBaseline
        let happyBeats = self == .happy && alternate ? Self.happyVariantBeats[variant] : nil
        guard let beats = happyBeats ?? Self.beats[self] else { return pose }
        let age = motionTime(at: elapsed, playbackDuration: playbackDuration)
        var time = age.truncatingRemainder(dividingBy: motionDuration)
        if self == .charging && age >= motionDuration {
            let connected = 1.16
            time = connected + time * (motionDuration - connected) / motionDuration
        }
        let repeating = self != .idle && (isBaseline || age >= motionDuration)
        var previous = Beat(time: 0, pose: repeating ? (beats.last?.pose ?? pose) : Self.idle.pose)
        var result = previous.pose
        for next in beats {
            if time <= next.time {
                result = previous.pose.blended(with: next.pose,
                                              progress: eased((time - previous.time) / (next.time - previous.time)))
                break
            }
            previous = next
            result = next.pose
        }
        if self == .idle && age.truncatingRemainder(dividingBy: motionDuration * 2) >= motionDuration {
            result.lookX *= -1
            swap(&result.left, &result.right)
        }
        if alternate, happyBeats == nil {
            applyMotion(variant, progress: time / motionDuration, to: &result)
        }
        return result
    }

    private var leanDirection: CGFloat {
        switch self {
        case .sad, .crying, .shy, .peeking, .confused, .dizzy: -1
        default: 1
        }
    }

    private var nodDistance: CGFloat {
        switch self {
        case .sad, .crying, .sleepy, .yawning: 4
        case .angry, .confused, .freezing: 5
        case .listening, .thinking, .curious, .peeking, .shy: -4
        default: -8
        }
    }

    private func applyMotion(_ variant: PetExpressionVariant, progress: Double, to pose: inout PetPose) {
        switch variant {
        case .original:
            break
        case .second:
            let first = motionPulse(progress, start: 0.09, peak: 0.22, end: 0.37)
            let second = motionPulse(progress, start: 0.38, peak: 0.48, end: 0.63)
            let nod = first + second * 0.5
            pose.bounce += nodDistance * nod
            pose.left.height *= 1 + nod * 0.11
            pose.right.height *= 1 + nod * 0.11
        case .third:
            let lean = eased((progress - 0.14) / 0.22) * (1 - eased((progress - 0.63) / 0.26))
            let direction = lean * leanDirection
            // Keep the entrance and exit positions of large actions such as peeking.
            let room = max(0, 1 - abs(pose.lookX) / 30)
            pose.lookX += direction * 17 * room
            pose.left.lift += direction * 4
            pose.right.lift -= direction * 4
            pose.bounce += nodDistance * 0.5 * lean
        }
    }

    private func motionPulse(_ progress: Double, start: Double, peak: Double, end: Double) -> CGFloat {
        eased((progress - start) / (peak - start)) * (1 - eased((progress - peak) / (end - peak)))
    }

    private func happySmile(for variant: PetExpressionVariant) -> PetPose {
        var smile = pose
        switch variant {
        case .original:
            break
        case .second:
            smile.left.width = 1.43
            smile.right.width = 1.43
            smile.mouthOpen = 0.54
            smile.cheeks = 0.92
        case .third:
            smile.left = EyePose(width: 1.28, height: 0.22, tilt: -0.12, curve: -35, lift: -5, lidWeight: 13.2)
            smile.right = EyePose(width: 1.16, height: 0.42, tilt: 0.12, curve: -24, lift: 3, lidWeight: 11)
            smile.smirk = 0.44
            smile.cheeks = 0.86
        }
        return smile
    }

    private static let happyVariantBeats: [PetExpressionVariant: [Beat]] = {
        let hop = Self.happy.happySmile(for: .second)
        let grin = Self.happy.happySmile(for: .third)
        return [
            .second: [
                Beat(time: 0.12, pose: Self.idle.pose),
                Beat(time: 0.24, pose: hop),
                Beat(time: 0.40, pose: hop) { $0.bounce = -12 },
                Beat(time: 0.61, pose: hop) { $0.bounce = 2; $0.mouthOpen = 0.30 },
                Beat(time: 0.86, pose: hop) { $0.bounce = -9; $0.mouthOpen = 0.48 },
                Beat(time: 1.10, pose: hop),
                Beat(time: 1.38, pose: Self.happy.pose),
                Beat(time: 1.65, pose: Self.idle.pose)
            ],
            .third: [
                Beat(time: 0.13, pose: Self.idle.pose),
                Beat(time: 0.28, pose: grin),
                Beat(time: 0.45, pose: grin) { $0.lookX = 19; $0.lookY = -5 },
                Beat(time: 0.66, pose: grin) { $0.lookX = 14; $0.lookY = -3 },
                Beat(time: 0.95, pose: grin) { $0.lookX = -11; $0.lookY = -3 },
                Beat(time: 1.18, pose: grin) { $0.lookX = -5 },
                Beat(time: 1.40, pose: Self.happy.pose),
                Beat(time: 1.65, pose: Self.idle.pose)
            ]
        ]
    }()

    private static let beats: [Self: [Beat]] = {
        @MainActor func at(_ time: TimeInterval, _ expression: Self, _ change: (inout PetPose) -> Void = { _ in }) -> Beat {
            Beat(time: time, pose: expression.pose, change)
        }

        return [
            .idle: [
                at(1.66, .idle),
                at(1.73, .idle) { $0.left.height = 0.08; $0.right.height = 0.08 },
                at(1.84, .idle),
                at(3.80, .idle),
                at(4.02, .idle) { $0.lookX = -9; $0.right.height = 0.96 },
                at(4.46, .idle) { $0.lookX = -9; $0.right.height = 0.96 },
                at(4.72, .idle),
                at(6.43, .idle),
                at(6.51, .idle) { $0.left.height = 0.08; $0.right.height = 0.08 },
                at(6.62, .idle),
                at(6.76, .idle) { $0.left.height = 0.13; $0.right.height = 0.13 },
                at(6.86, .idle),
                at(9.34, .idle),
                at(9.56, .idle) { $0.lookX = 8; $0.lookY = -3 },
                at(10.12, .idle) { $0.lookX = 8; $0.lookY = -3 },
                at(10.37, .idle)
            ],
            .happy: [
                at(0.08, .idle) { $0.left.height = 1.12; $0.right.height = 1.20; $0.lookY = -5 },
                at(0.16, .happy) {
                    $0.left = EyePose(width: 1.09, height: 0.53, tilt: -0.08, lift: -7)
                    $0.right.shift = 6
                    $0.right.lift = -8
                    $0.cheeks = 0.45
                },
                at(0.27, .happy) {
                    $0.left.width = 1.52; $0.left.shift = -11; $0.left.lift = -8
                    $0.right.width = 1.48; $0.right.shift = 10; $0.right.lift = -5
                    $0.cheeks = 0.88
                },
                at(0.44, .happy) {
                    $0.left.shift = -3; $0.right.shift = 3
                    $0.left.lift = 0; $0.right.lift = 1
                },
                at(0.66, .happy) {
                    $0.left.shift = -5; $0.right.shift = 5
                    $0.right.lift = -6; $0.right.tilt = 0.08; $0.lookX = 5
                },
                at(0.90, .happy) { $0.left.lift = -4; $0.lookX = 2 },
                at(1.18, .happy),
                at(1.37, .happy) { $0.right.height = 0.42; $0.right.width = 1.10; $0.cheeks = 0.42 },
                at(1.55, .idle) { $0.left.height = 0.87; $0.right.height = 1.05 },
                at(1.71, .idle)
            ],
            .angry: [
                at(0.10, .idle) { $0.left.height = 0.34; $0.right.height = 0.34 },
                at(0.21, .angry) { $0.anger = 1; $0.bounce = 3 },
                at(0.38, .angry),
                at(0.88, .angry),
                at(1.00, .idle) { $0.left.height = 0.13; $0.right.height = 0.13; $0.anger = 0.15 }
            ],
            .celebrate: [
                at(0.08, .idle) { $0.left.height = 0.10; $0.right.height = 0.10 },
                at(0.19, .celebrate), at(0.93, .celebrate),
                at(1.12, .idle) { $0.left.height = 0.11; $0.right.height = 0.11 },
                at(1.22, .idle)
            ],
            .delighted: [
                at(0.09, .idle) { $0.left.height = 0.10; $0.right.height = 0.10 },
                at(0.20, .delighted), at(1.12, .delighted),
                at(1.29, .idle) { $0.left.height = 0.14; $0.right.height = 0.14 },
                at(1.39, .idle)
            ],
            .cool: [
                at(0.08, .idle),
                at(0.24, .cool),
                at(0.47, .cool),
                at(0.61, .cool) { $0.lookX = 9; $0.bounce = -7 },
                at(0.81, .cool) { $0.lookX = 17; $0.bounce = -3 },
                at(1.19, .cool) { $0.lookX = 13; $0.bounce = -2 },
                at(1.52, .cool), at(1.77, .cool),
                at(1.98, .idle)
            ],
            .affectionate: [
                at(0.13, .idle) { $0.left.height = 0.14; $0.right.height = 0.14 },
                at(0.30, .affectionate) { $0.bounce = -8 },
                at(0.52, .affectionate), at(1.45, .affectionate),
                at(1.97, .happy)
            ],
            .sleepy: [
                at(0.65, .idle) { $0.left.height = 0.61; $0.right.height = 0.48 },
                at(1.24, .sleepy), at(2.79, .sleepy),
                at(3.08, .idle) { $0.left.height = 0.62; $0.right.height = 0.45 }
            ],
            .dizzy: [
                at(0.18, .idle) { $0.lookX = -10 },
                at(0.39, .dizzy) { $0.lookX = 9 },
                at(0.57, .dizzy) { $0.lookX = -6 },
                at(0.83, .dizzy), at(1.94, .dizzy), at(2.21, .curious)
            ],
            .laughing: [
                at(0.21, .happy), at(0.37, .laughing) { $0.bounce = -11 },
                at(0.58, .laughing) { $0.mouthOpen = 0.56; $0.left.height = 0.31; $0.lookX = 4 },
                at(0.78, .laughing) { $0.bounce = -8; $0.right.height = 0.26 },
                at(1.0, .laughing) { $0.mouthOpen = 0.52; $0.lookX = -5; $0.right.height = 0.34 },
                at(1.2, .laughing) { $0.bounce = -5; $0.left.height = 0.27 }, at(1.90, .happy)
            ],
            .winking: [
                at(0.23, .happy), at(0.43, .winking), at(0.92, .winking), at(1.36, .happy)
            ],
            .listening: [
                at(0.19, .listening) { $0.bounce = -3 },
                at(0.42, .listening),
                at(1.14, .listening) { $0.lookX = -2; $0.lookY = -8 },
                at(1.90, .listening) { $0.lookX = 2 },
                at(2.28, .listening),
                at(2.39, .listening) { $0.left.height = 0.23; $0.right.height = 0.23 },
                at(2.54, .listening),
                at(2.85, .listening)
            ],
            .thinking: [
                at(0.47, .thinking), at(1.86, .thinking), at(2.27, .curious) { $0.lookX = 0 }
            ],
            .confused: [
                at(0.30, .confused), at(0.96, .confused),
                at(1.25, .confused) { $0.lookX = 10; ($0.left, $0.right) = ($0.right, $0.left) },
                at(1.67, .curious)
            ],
            .peeking: [
                at(0.31, .peeking) { $0.lookX = -147; $0.lookY = 60 },
                at(0.72, .peeking), at(1.28, .peeking),
                at(1.69, .peeking) { $0.lookX = 76; $0.lookY = 25 },
                at(2.15, .happy)
            ],
            .yawning: [
                at(0.46, .sleepy) { $0.sleep = 0; $0.lookY = 2 },
                at(0.98, .yawning) { $0.bounce = -5 }, at(1.52, .yawning),
                at(2.14, .sleepy)
            ],
            .kiss: [
                at(0.28, .shy), at(0.54, .kiss), at(1.25, .kiss),
                at(1.77, .happy)
            ],
            .hungry: [
                at(0.33, .hungry), at(1.16, .hungry),
                at(1.46, .hungry) { $0.lookX = -7; $0.mouthOpen = 0.18 },
                at(1.94, .hungry) { $0.lookX = 5 }
            ],
            .munching: [
                at(0.30, .hungry), at(0.55, .munching) { $0.mouthOpen = 0.83 },
                at(0.80, .munching) { $0.mouthOpen = 0.12 },
                at(1.02, .munching) { $0.mouthOpen = 0.67 },
                at(1.23, .munching) { $0.mouthOpen = 0.12 },
                at(1.43, .munching), at(2.22, .happy)
            ],
            .bubbles: [
                at(0.46, .bubbles), at(1.56, .bubbles),
                at(2.12, .bubbles) { $0.mouthOpen = 0.18; $0.lookY = -9 }
            ],
            .freezing: [
                at(0.19, .surprised), at(0.45, .freezing), at(1.82, .freezing),
                at(2.15, .curious)
            ],
            .dancing: [
                at(0.30, .dancing) { $0.lookX = -13; $0.bounce = -7 },
                at(0.71, .dancing) { $0.lookX = 13; ($0.left, $0.right) = ($0.right, $0.left) },
                at(1.12, .dancing) { $0.lookX = -13; $0.bounce = -7 },
                at(1.53, .dancing) { $0.lookX = 13; ($0.left, $0.right) = ($0.right, $0.left) },
                at(1.94, .dancing) { $0.lookX = -10; $0.bounce = -7 }, at(2.53, .happy)
            ],
            .handHeart: [
                at(0.20, .idle) { $0.lookY = 9 },
                at(0.55, .handHeart) { $0.lookY = 5 },
                at(0.95, .handHeart) { $0.bounce = -6 },
                at(1.80, .handHeart),
                at(2.07, .happy)
            ],
            .thumbsUp: [
                at(0.22, .happy), at(0.46, .thumbsUp) { $0.bounce = -7 },
                at(0.71, .thumbsUp), at(1.51, .thumbsUp), at(1.81, .happy)
            ],
            .maracas: [
                at(0.42, .maracas) { $0.lookX = -8 }, at(0.79, .maracas) { $0.lookX = 8 },
                at(1.18, .maracas) { $0.lookX = -8 }, at(1.57, .maracas) { $0.lookX = 8 },
                at(1.96, .maracas) { $0.lookX = -8 }, at(2.46, .maracas),
                at(2.72, .happy)
            ],
            .charging: [
                at(0.18, .idle) { $0.lookX = 14; $0.lookY = 6 },
                at(0.56, .charging) { $0.lookX = 10 },
                at(0.82, .charging) { $0.bounce = -5; $0.left.height = 0.84; $0.right.height = 0.84 },
                at(1.16, .charging), at(2.31, .charging),
                at(2.46, .charging) { $0.left.height = 0.13; $0.right.height = 0.13 },
                at(2.63, .charging), at(3.32, .charging)
            ],
            .charged: [
                at(0.15, .idle) { $0.left.height = 0.15; $0.right.height = 0.15 },
                at(0.34, .charged) { $0.bounce = -9 }, at(1.65, .charged), at(1.97, .happy)
            ],
            .greeting: [
                at(0.18, .idle) { $0.lookX = 13; $0.right.height = 1.16 },
                at(0.38, .greeting) { $0.bounce = -10; $0.right.height = 0.15; $0.right.curve = -24 },
                at(0.53, .greeting) { $0.right.height = 1.12; $0.lookY = -5 },
                at(0.88, .greeting) { $0.lookX = -5; $0.left.height = 0.80 },
                at(1.16, .greeting) { $0.lookX = 5; $0.right.lift = -4 },
                at(1.60, .happy) { $0.cheeks = 0.34 }
            ],
            .shy: [
                at(0.36, .shy), at(0.85, .shy),
                at(1.20, .shy) { $0.lookX = -6; $0.right.height = 1.04; $0.right.lift = -8 },
                at(1.50, .shy) { $0.lookX = -6; $0.right.height = 1.04; $0.right.lift = -8 },
                at(1.82, .shy) { $0.left.height = 0.14; $0.right.height = 0.14 },
                at(2.16, .happy) { $0.cheeks = 0.55 }
            ],
            .musical: [
                at(0.37, .musical) { $0.lookX = -9; $0.bounce = -5 },
                at(0.85, .musical) { $0.lookX = 9; $0.mouthOpen = 0.2 },
                at(1.33, .musical) { $0.lookX = -9; $0.bounce = -5 },
                at(1.81, .musical) { $0.lookX = 9; $0.mouthOpen = 0.2 },
                at(2.29, .musical) { $0.lookX = -6; $0.bounce = -4 },
                at(2.61, .happy)
            ],
            .proud: [
                at(0.30, .proud) { $0.lookY = -8 },
                at(0.86, .proud) { $0.lookY = -7 },
                at(1.04, .proud) { $0.left.height = 0.12; $0.left.curve = -75; $0.smirk = 1.15 },
                at(1.28, .proud),
                at(2.2, .proud) { $0.lookX = 8; $0.lookY = -4 }
            ],
            .sad: [
                at(0.24, .idle) { $0.left.height = 0.67; $0.right.height = 0.78; $0.lookY = 4 },
                at(0.55, .sad) { $0.lookY = 16; $0.left.lift = 9; $0.right.lift = 7 },
                at(0.86, .sad) { $0.lookY = 12 },
                at(1.30, .sad) { $0.lookX = -8; $0.right.lift = 8 },
                at(1.65, .sad) { $0.lookX = -5; $0.lookY = 14; $0.left.curve = 34 },
                at(2.37, .sad) { $0.lookY = 12 },
                at(2.88, .sad) { $0.left.height = 0.45; $0.right.height = 0.53; $0.lookY = 2 },
                at(3.20, .idle)
            ],
            .crying: [
                at(0.33, .sad), at(0.68, .sad) { $0.tears = 0.34 },
                at(0.97, .crying) { $0.mouthOpen = 0.46; $0.bounce = 5 },
                at(1.26, .crying),
                at(1.55, .crying) { $0.mouthOpen = 0.34; $0.bounce = 3 },
                at(2.05, .crying),
                at(2.57, .sad) { $0.tears = 0.52 },
                at(3.19, .sad) { $0.tears = 0.15; $0.lookY = 2 }
            ],
            .surprised: [
                at(0.10, .idle) { $0.left.height = 0.53; $0.right.height = 0.53 },
                at(0.24, .surprised) { $0.bounce = -8 },
                at(0.44, .surprised),
                at(0.91, .surprised),
                at(1.10, .surprised) { $0.left.height = 0.13; $0.right.height = 0.14 },
                at(1.36, .curious),
                at(1.85, .curious)
            ],
            .curious: [
                at(0.26, .idle) { $0.lookX = 17 },
                at(0.47, .curious),
                at(1.14, .curious),
                at(1.42, .curious) {
                    $0.lookX = -16
                    $0.left = EyePose(height: 1.08, tilt: -0.12, lift: -7)
                    $0.right = EyePose(height: 0.81, tilt: -0.10, lift: 4)
                },
                at(2.19, .curious) { $0.lookX = 0; $0.lookY = 5 },
                at(2.61, .happy) { $0.cheeks = 0.32 }
            ]
        ]
    }()
}

private func eased(_ progress: Double) -> CGFloat {
    let t = CGFloat(min(max(progress, 0), 1))
    return t * t * (3 - 2 * t)
}

private func mix(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
    start + (end - start) * progress
}
