import SwiftUI

struct PetCatchGame: View {
    let onExit: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = Phase.ready
    @State private var thrown = 0
    @State private var caught = 0
    @State private var playback = PetPlayback()
    @State private var accumulatedTime: TimeInterval = 0
    @State private var activeSince: TimeInterval?

    private static let throwLimit = 3
    private static let launch = CGPoint(x: 0.5, y: 0.84)
    private static let target = CGPoint(x: 0.5, y: 0.39)
    private static let targetRadius = CGSize(width: 0.115, height: 0.072)
    private static let courtColor = Color(red: 0.48, green: 0.83, blue: 0.97)

    private enum Phase {
        case ready
        case flying(Flight)
        case reacting(Flight)
        case finished

        var canThrow: Bool {
            if case .ready = self { return true }
            return false
        }

        var isFinished: Bool {
            if case .finished = self { return true }
            return false
        }

        var flight: Flight? {
            switch self {
            case .flying(let flight), .reacting(let flight): flight
            case .ready, .finished: nil
            }
        }
    }

    private struct Flight {
        private static let gravity: CGFloat = 2.8
        let start: TimeInterval
        let velocity: CGVector
        let impact: TimeInterval
        let caught: Bool
        let end: TimeInterval

        init(start: TimeInterval, velocity: CGVector) {
            self.start = start
            self.velocity = velocity

            let drop = 0.99 - PetCatchGame.launch.y
            let landing = (-velocity.dy + sqrt(velocity.dy * velocity.dy + 2 * Self.gravity * drop)) / Self.gravity
            // Intersect the visible catch area with the ball's path before it lands.
            let hit = stride(from: 0.0, through: Double(landing), by: 1.0 / 120).first { elapsed in
                let point = Self.position(at: elapsed, velocity: velocity)
                let x = (point.x - PetCatchGame.target.x) / PetCatchGame.targetRadius.width
                let y = (point.y - PetCatchGame.target.y) / PetCatchGame.targetRadius.height
                return x * x + y * y <= 1
            }
            impact = hit ?? Double(landing)
            caught = hit != nil
            end = impact + (caught ? 0.48 : 0.24)
        }

        private static func position(at elapsed: TimeInterval, velocity: CGVector) -> CGPoint {
            let time = CGFloat(elapsed)
            return CGPoint(x: PetCatchGame.launch.x + velocity.dx * time,
                           y: PetCatchGame.launch.y + velocity.dy * time + Self.gravity * time * time / 2)
        }

        func ball(at time: TimeInterval) -> (position: CGPoint, opacity: Double) {
            let elapsed = max(0, time - start)
            let point = Self.position(at: min(elapsed, impact), velocity: velocity)
            guard elapsed > impact else { return (point, 1) }
            let progress = min(1, (elapsed - impact) / (end - impact))
            guard caught else { return (point, 1 - progress) }
            let landing = PetCatchGame.launch
            return (CGPoint(x: point.x + (landing.x - point.x) * progress,
                            y: point.y + (landing.y - point.y) * progress - 0.2 * progress * (1 - progress)), 1)
        }

    }

    var body: some View {
        VStack(spacing: 8) {
            header

            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: scenePhase != .active)) { _ in
                let time = gameTime
                GeometryReader { geometry in
                    court(size: geometry.size, time: time)
                }
                .onChange(of: time) { _, current in advance(at: current) }
            }

            footer
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.035).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase, initial: true) { _, phase in
            updateClock(isActive: phase == .active)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("扔球接球")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("退出", action: onExit)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text(status)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            if phase.isFinished {
                HStack(spacing: 12) {
                    Button("再玩一次", action: restart)
                        .buttonStyle(.borderedProminent)
                    Button("完成", action: onExit)
                        .buttonStyle(.bordered)
                }
            } else {
                Button("投球") { throwBall(velocity: CGVector(dx: 0, dy: -1.75)) }
                    .buttonStyle(.bordered)
                    .disabled(!phase.canThrow)
                    .accessibilityHint("把球抛向圆圆的接球区")
            }
        }
        .controlSize(.large)
        .tint(Self.courtColor)
        .frame(maxWidth: .infinity)
    }

    private var status: String {
        let score = "接到 \(caught) / \(Self.throwLimit)"
        switch phase {
        case .ready:
            return "第 \(thrown + 1) 球 / 共 \(Self.throwLimit) 球 · 向上划，把球抛给圆圆"
        case .flying:
            return "第 \(thrown + 1) 球 / 共 \(Self.throwLimit) 球"
        case .reacting(let flight):
            return flight.caught ? "接住啦！\(score)" : "没接到。\(score)"
        case .finished:
            return score
        }
    }

    private func court(size: CGSize, time: TimeInterval) -> some View {
        let launch = point(Self.launch, in: size)
        let target = point(Self.target, in: size)
        let ball = phase.flight.map { $0.ball(at: time) } ?? (position: Self.launch, opacity: 1.0)
        let ballCenter = point(ball.position, in: size)
        let faceCenter = point(CGPoint(x: 0.5, y: 0.175), in: size)
        let faceWidth = min(size.width * 0.66, size.height * 0.97)
        let faceHeight = faceWidth * 215 / 475
        var pose = reduceMotion ? playback.stillPose(at: time) : playback.pose(at: time)
        if case .flying = phase, !reduceMotion {
            pose.lookX += min(48, max(-48, (ball.position.x - 0.5) * 130))
            pose.lookY += min(24, max(0, (ball.position.y - 0.175) * 42))
        }

        return ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(white: 0.09))
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)

            PetFace(pose: pose, time: time, elapsed: playback.effectElapsed(at: time), mouthEnabled: true,
                    motionEnabled: !reduceMotion, drawingSize: CGSize(width: faceWidth, height: faceHeight),
                    centerOffset: CGSize(width: 0, height: faceCenter.y - size.height / 2))
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)

            if !phase.isFinished {
                Ellipse()
                    .fill(Self.courtColor.opacity(0.10))
                    .overlay {
                        Ellipse().strokeBorder(Self.courtColor.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                    .overlay { Image(systemName: "scope").font(.caption).foregroundStyle(Self.courtColor) }
                    .frame(width: size.width * 2 * Self.targetRadius.width, height: size.height * 2 * Self.targetRadius.height)
                    .position(target)

                if thrown == 0, phase.canThrow {
                    firstThrowHint(size: size)
                }

                Circle()
                    .fill(Color(red: 1, green: 0.76, blue: 0.31))
                    .overlay(alignment: .topLeading) {
                        Circle().fill(.white.opacity(0.60)).frame(width: 7, height: 7).padding(5)
                    }
                    .frame(width: 26, height: 26)
                    .opacity(ball.opacity)
                    .position(ballCenter)

                if phase.canThrow {
                    Rectangle().fill(.clear)
                        .contentShape(Rectangle())
                        .frame(width: size.width * 0.70, height: size.height * 0.32)
                        .position(launch)
                        .gesture(DragGesture(minimumDistance: 8).onEnded { drag in
                            throwBall(with: drag, size: size)
                        })
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityHidden(true)
    }

    private func firstThrowHint(size: CGSize) -> some View {
        Path { path in
            path.move(to: point(CGPoint(x: 0.5, y: 0.72), in: size))
            path.addLine(to: point(CGPoint(x: 0.5, y: 0.57), in: size))
        }
        .stroke(.white.opacity(0.38), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))
        .overlay {
            Image(systemName: "chevron.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .position(point(CGPoint(x: 0.5, y: 0.55), in: size))
        }
    }

    private func point(_ unitPoint: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: unitPoint.x * size.width, y: unitPoint.y * size.height)
    }

    private var gameTime: TimeInterval {
        guard let activeSince else { return accumulatedTime }
        return accumulatedTime + ProcessInfo.processInfo.systemUptime - activeSince
    }

    private func updateClock(isActive: Bool) {
        if isActive, activeSince == nil {
            activeSince = ProcessInfo.processInfo.systemUptime
        } else if !isActive, activeSince != nil {
            accumulatedTime = gameTime
            activeSince = nil
        }
    }

    private func throwBall(with drag: DragGesture.Value, size: CGSize) {
        let distance = drag.translation
        guard distance.height <= -8 else { return }
        let end = drag.predictedEndTranslation
        let rise = max(-distance.height, -end.height)
        let sideways = (distance.width + end.width) / 2
        let strength = min(2.25, 0.54 + rise / max(52, size.height * 0.31))
        let bearing = min(1.1, max(-1.1, sideways / max(16, (rise - distance.height) / 2)))
        throwBall(velocity: CGVector(dx: bearing * strength * size.height / max(1, size.width), dy: -strength))
    }

    private func throwBall(velocity: CGVector) {
        guard phase.canThrow, scenePhase == .active else { return }
        phase = .flying(Flight(start: gameTime, velocity: velocity))
    }

    private func advance(at time: TimeInterval) {
        switch phase {
        case .flying(let flight) where time >= flight.start + flight.impact:
            thrown += 1
            if flight.caught { caught += 1 }
            let expression: PetExpression
            if caught == Self.throwLimit {
                expression = .celebrate
            } else {
                expression = flight.caught ? .happy : .surprised
            }
            playback.react(expression, at: time, priority: .immediate)
            phase = .reacting(flight)
            AccessibilityNotification.Announcement(status).post()
        case .reacting(let flight) where time >= flight.start + flight.end && !playback.hasActiveSelection(at: time):
            phase = thrown == Self.throwLimit ? .finished : .ready
            if phase.isFinished { AccessibilityNotification.Announcement(status).post() }
        default:
            break
        }
    }

    private func restart() {
        thrown = 0
        caught = 0
        playback = PetPlayback()
        phase = .ready
    }
}
