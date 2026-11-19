import SwiftUI
import UIKit

struct PetCatchGame: View {
    let onExit: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var drag: DragGesture.Value?
    @State private var phase = Phase.ready
    @State private var results: [Bool] = []
    @State private var playback = PetPlayback()
    @State private var accumulatedTime: TimeInterval = 0
    @State private var activeSince: TimeInterval?

    private static let launch = CGPoint(x: 0.5, y: 0.83)
    private static let targets = [
        CGPoint(x: 0.50, y: 0.47),
        CGPoint(x: 0.37, y: 0.47),
        CGPoint(x: 0.63, y: 0.47)
    ]
    private static let targetRadius = CGSize(width: 0.13, height: 0.105)
    private static let courtColor = Color(red: 0.48, green: 0.83, blue: 0.97)

    private enum Phase {
        case ready
        case flying(Flight)
        case returning(Flight)
        case finished

        var canThrow: Bool {
            if case .ready = self { return true }
            return false
        }

        var flight: Flight? {
            switch self {
            case .flying(let flight), .returning(let flight): flight
            default: nil
            }
        }
    }

    private struct Shot {
        let origin: CGPoint
        let velocity: CGVector
        private static let gravity: CGFloat = 2.8

        func point(at elapsed: TimeInterval) -> CGPoint {
            let t = CGFloat(elapsed)
            return CGPoint(x: origin.x + velocity.dx * t,
                           y: origin.y + velocity.dy * t + 0.5 * Self.gravity * t * t)
        }

        var landingTime: TimeInterval {
            let drop = 1.08 - origin.y
            return Double((-velocity.dy + sqrt(velocity.dy * velocity.dy + 2 * Self.gravity * drop)) / Self.gravity)
        }

        static func aimed(at target: CGPoint) -> Self {
            let flightTime: CGFloat = 0.31
            return Self(origin: launch, velocity: CGVector(
                dx: (target.x - launch.x) / flightTime,
                dy: (target.y - launch.y) / flightTime - 0.5 * gravity * flightTime
            ))
        }
    }

    private struct Flight {
        let start: TimeInterval
        let shot: Shot
        let target: CGPoint
        let impact: TimeInterval
        let caught: Bool

        init(start: TimeInterval, shot: Shot, target: CGPoint) {
            self.start = start
            self.shot = shot
            self.target = target
            let hit = stride(from: 0.0, through: shot.landingTime, by: 1.0 / 120).first { elapsed in
                let point = shot.point(at: elapsed)
                let x = (point.x - target.x) / targetRadius.width
                let y = (point.y - target.y) / targetRadius.height
                return x * x + y * y <= 1
            }
            caught = hit != nil
            impact = hit ?? shot.landingTime
        }

        var returnStart: TimeInterval { impact + (caught ? 0.22 : 0.08) }
        var end: TimeInterval { returnStart + (caught ? 0.53 : 0.32) }

        func ball(at time: TimeInterval) -> (position: CGPoint, opacity: Double) {
            let elapsed = max(0, time - start)
            let contact = shot.point(at: impact)
            guard elapsed > impact else { return (shot.point(at: elapsed), 1) }
            if !caught {
                let progress = min(1, max(0, (elapsed - returnStart) / (end - returnStart)))
                return (launch, progress)
            }
            let hold = CGFloat(min(1, (elapsed - impact) / (returnStart - impact)))
            let smoothHold = hold * hold * (3 - 2 * hold)
            let glove = CGPoint(x: target.x, y: target.y + 0.07)
            if elapsed < returnStart {
                return (CGPoint(x: contact.x + (glove.x - contact.x) * smoothHold,
                                y: contact.y + (glove.y - contact.y) * smoothHold), 1)
            }
            let t = CGFloat(min(1, (elapsed - returnStart) / (end - returnStart)))
            return (CGPoint(x: glove.x + (launch.x - glove.x) * t,
                            y: glove.y + (launch.y - glove.y) * t - 0.24 * t * (1 - t)), 1)
        }
    }

    private var target: CGPoint {
        phase.flight?.target ?? Self.targets[min(results.count, Self.targets.count - 1)]
    }

    private var caught: Int { results.filter { $0 }.count }

    var body: some View {
        VStack(spacing: 6) {
            header
            TimelineView(.animation(minimumInterval: frameInterval, paused: scenePhase != .active)) { _ in
                let time = gameTime
                GeometryReader { geometry in
                    court(size: geometry.size, time: time)
                }
                .onChange(of: time) { _, current in advance(at: current) }
            }
            footer
        }
        .frame(maxWidth: 580)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(colors: [Color(red: 0.08, green: 0.12, blue: 0.19), Color(white: 0.035)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            updateClock(isActive: phase == .active)
        }
    }

    private var frameInterval: TimeInterval? {
        let constrained = reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled
            || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
        return (phase.flight != nil || drag != nil) && !constrained ? nil : 1.0 / 30
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("扔球接球")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            HStack(spacing: 5) {
                ForEach(Self.targets.indices, id: \.self) { index in
                    let result = results.indices.contains(index) ? results[index] : nil
                    Image(systemName: result.map { $0 ? "checkmark.circle.fill" : "xmark.circle.fill" } ?? "circle")
                        .foregroundStyle(result == true ? Self.courtColor : .secondary)
                }
            }
            .accessibilityLabel("已投 \(results.count) 球，接到 \(caught) 球")
            Button("退出", action: onExit)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(status)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            if case .finished = phase {
                Button("再玩一次", action: restart)
                    .buttonStyle(.borderedProminent)
                Button("完成", action: onExit)
                    .buttonStyle(.bordered)
            } else {
                Button("投给圆圆") { throwBall(Shot.aimed(at: target)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!phase.canThrow)
            }
        }
        .controlSize(.large)
        .tint(Self.courtColor)
    }

    private var status: String {
        switch phase {
        case .ready:
            if drag != nil { return "松手投球" }
            return results.isEmpty ? "拖着球朝圆圆的手滑，再松开" : "轮到你啦，投下一球"
        case .flying:
            return "圆圆盯住球了"
        case .returning(let flight):
            return flight.caught ? "接住啦，还给你！" : "差一点，再来一球"
        case .finished:
            return caught == Self.targets.count ? "三球全接住！" : "这轮接到 \(caught) / \(Self.targets.count) 球"
        }
    }

    private func court(size: CGSize, time: TimeInterval) -> some View {
        let shot = drag.map { aim(with: $0, in: size) }
        let ball = phase.flight?.ball(at: time) ?? (position: shot?.origin ?? Self.launch, opacity: 1)
        let ballCenter = point(ball.position, in: size)
        let faceWidth = min(size.width * 0.62, size.height * 1.42)
        var pose = reduceMotion ? playback.stillPose(at: time) : playback.pose(at: time)
        if !reduceMotion, drag != nil || phase.flight != nil {
            pose.lookX += min(45, max(-45, (ball.position.x - 0.5) * 135)) * ball.opacity
            pose.lookY += min(20, max(-8, (ball.position.y - 0.30) * 35)) * ball.opacity
        }

        return ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(colors: [Self.courtColor.opacity(0.12), .white.opacity(0.035)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.white.opacity(0.12))

            PetFace(pose: pose, time: time, elapsed: playback.effectElapsed(at: time), mouthEnabled: true,
                    motionEnabled: !reduceMotion, drawingSize: CGSize(width: faceWidth, height: faceWidth * 215 / 475),
                    centerOffset: CGSize(width: 0, height: -size.height * 0.27))
                .allowsHitTesting(false)

            if case .finished = phase {
                EmptyView()
            } else {
                glove(in: size, time: time)
                if let shot, shot.velocity.dy < -0.7, phase.canThrow {
                    trajectory(for: shot, in: size)
                }
                ballView
                    .opacity(ball.opacity)
                    .position(ballCenter)
                if phase.canThrow {
                    Circle()
                        .fill(.clear)
                        .contentShape(Circle())
                        .frame(width: 58, height: 58)
                        .position(point(Self.launch, in: size))
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("catchCourt"))
                                .updating($drag) { value, state, transaction in
                                    transaction.animation = nil
                                    state = value
                                }
                                .onEnded { value in
                                    guard value.translation.height <= -8 else { return }
                                    throwBall(aim(with: value, in: size))
                                }
                        )
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "catchCourt")
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .accessibilityHidden(true)
    }

    private func glove(in size: CGSize, time: TimeInterval) -> some View {
        let flight = phase.flight
        let elapsed = flight.map { time - $0.start } ?? 0
        let holding = flight.map { $0.caught && elapsed >= $0.impact && elapsed < $0.returnStart } ?? false
        let extensionAmount: CGFloat = if let flight, !reduceMotion {
            min(1, max(0, elapsed / min(0.2, flight.impact)))
        } else {
            drag == nil || reduceMotion ? 0 : 1
        }
        var recoil: CGFloat = 0
        if let flight, flight.caught, !reduceMotion, elapsed >= flight.impact {
            let hold = CGFloat(min(1, (elapsed - flight.impact) / (flight.returnStart - flight.impact)))
            let release = CGFloat(min(1, max(0, (elapsed - flight.returnStart) / 0.15)))
            recoil = 0.07 * hold * hold * (3 - 2 * hold) * (1 - release * release * (3 - 2 * release))
        }
        let hand = point(CGPoint(x: target.x, y: target.y - 0.04 * (1 - extensionAmount) + recoil), in: size)
        let shoulder = point(CGPoint(x: 0.5 + (target.x - 0.5) * 0.35, y: 0.27), in: size)
        return ZStack {
            Path { path in
                path.move(to: shoulder)
                path.addQuadCurve(to: hand, control: CGPoint(x: shoulder.x, y: hand.y))
            }
            .stroke(Self.courtColor.opacity(0.32 + extensionAmount * 0.18),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round))

            Image(systemName: holding ? "hand.raised.fill" : "hand.raised")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(holding ? Color.yellow : Self.courtColor)
                .frame(width: 42, height: 42)
                .background(Color(red: 0.13, green: 0.21, blue: 0.29), in: Circle())
                .overlay { Circle().strokeBorder(Self.courtColor.opacity(holding ? 0.85 : 0.50)) }
                .scaleEffect(holding && !reduceMotion ? 1.12 : 1)
                .position(hand)
        }
        .allowsHitTesting(false)
    }

    private var ballView: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 1, green: 0.90, blue: 0.54), .orange],
                                 center: .topLeading, startRadius: 1, endRadius: 32))
            .overlay {
                Circle().strokeBorder(.white.opacity(0.38))
            }
            .frame(width: 28, height: 28)
            .allowsHitTesting(false)
    }

    private func trajectory(for shot: Shot, in size: CGSize) -> some View {
        let flight = Flight(start: 0, shot: shot, target: target)
        return Path { path in
            path.move(to: point(shot.origin, in: size))
            for index in 1...16 {
                path.addLine(to: point(shot.point(at: flight.impact * Double(index) / 16), in: size))
            }
        }
        .stroke(flight.caught ? Self.courtColor : .white.opacity(0.42),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 6]))
        .allowsHitTesting(false)
    }

    private func point(_ unitPoint: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: unitPoint.x * size.width, y: unitPoint.y * size.height)
    }

    private func aim(with drag: DragGesture.Value, in size: CGSize) -> Shot {
        let movement = drag.translation
        let rise = max(0, -movement.height)
        // Small hand movements are enough on a short landscape court.
        let origin = CGPoint(
            x: Self.launch.x + min(0.29, max(-0.29, movement.width / max(1, size.width))),
            y: Self.launch.y - min(0.30, rise / max(1, size.height))
        )
        let projected = drag.predictedEndTranslation
        let lift = max(rise, -projected.height)
        let strength = min(2.1, 0.70 + lift / max(48, size.height * 0.56))
        let side = (movement.width * 0.65 + projected.width * 0.35) / max(1, size.width)
        let velocity = CGVector(dx: min(0.85, max(-0.85, side * 1.6)), dy: -strength)
        return Shot(origin: origin, velocity: velocity)
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

    private func throwBall(_ shot: Shot) {
        guard phase.canThrow, scenePhase == .active else { return }
        let time = gameTime
        playback.react(.listening, at: time, priority: .immediate)
        phase = .flying(Flight(start: time, shot: shot, target: target))
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func advance(at time: TimeInterval) {
        switch phase {
        case .flying(let flight) where time >= flight.start + flight.impact:
            results.append(flight.caught)
            let perfect = results.count == Self.targets.count && caught == Self.targets.count
            let expression: PetExpression = perfect ? .celebrate : flight.caught ? .happy : .surprised
            playback.react(expression, at: time, priority: .immediate)
            if flight.caught { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            phase = .returning(flight)
            AccessibilityNotification.Announcement(flight.caught ? "接住了" : "没接到").post()
        case .returning(let flight) where time >= flight.start + flight.end:
            if results.count == Self.targets.count {
                phase = .finished
                AccessibilityNotification.Announcement(status).post()
            } else {
                phase = .ready
                AccessibilityNotification.Announcement("轮到你投球").post()
            }
        default:
            break
        }
    }

    private func restart() {
        results.removeAll()
        playback.react(.greeting, at: gameTime, priority: .immediate)
        phase = .ready
    }
}
