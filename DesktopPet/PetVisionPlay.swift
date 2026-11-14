import Foundation

nonisolated struct VisionPlayFrame: Sendable {
    enum Trigger: Sendable { case pointReady, palmReady, palmPushed }

    let trigger: Trigger?
    let pointer: CGPoint?
}

nonisolated struct VisionPlayDetector {
    enum Pose {
        case pointing(CGPoint)
        case palm(wrist: CGPoint, scale: CGFloat)
    }

    private enum State {
        case ready
        case pointing(since: TimeInterval, fired: Bool)
        case palm(wrist: CGPoint, scale: CGFloat, since: TimeInterval)
        case raised(wrist: CGPoint, scale: CGFloat, pushFrames: Int)
        case spent
    }

    private var state = State.ready
    private var lastSeen: TimeInterval?

    mutating func update(_ pose: Pose?, waving: Bool, at time: TimeInterval) -> VisionPlayFrame {
        if let lastSeen, time - lastSeen > 0.28 { state = .ready }
        if waving { state = .spent }
        guard let pose else { return VisionPlayFrame(trigger: nil, pointer: nil) }
        lastSeen = time

        switch pose {
        case .pointing(let tip):
            var trigger: VisionPlayFrame.Trigger?
            switch state {
            case .pointing(let since, false) where time - since >= 0.30:
                state = .pointing(since: since, fired: true)
                trigger = .pointReady
            case .pointing:
                break
            default:
                state = .pointing(since: time, fired: false)
            }
            return VisionPlayFrame(trigger: trigger, pointer: tip)

        case .palm(let wrist, let scale):
            var trigger: VisionPlayFrame.Trigger?
            switch state {
            case .spent:
                break
            case .raised(let anchor, let baseline, let pushFrames):
                let pushed = scale >= baseline * 1.27 && distance(wrist, anchor) <= 0.19
                if pushed && pushFrames >= 1 {
                    trigger = .palmPushed
                    state = .spent
                } else {
                    state = .raised(wrist: anchor, scale: baseline, pushFrames: pushed ? pushFrames + 1 : 0)
                }
            case .palm(let anchor, let baseline, let since)
                where distance(wrist, anchor) <= 0.045 && abs(scale - baseline) <= baseline * 0.16:
                if time - since >= 0.65 {
                    trigger = .palmReady
                    state = .raised(wrist: wrist, scale: scale, pushFrames: 0)
                }
            default:
                state = .palm(wrist: wrist, scale: scale, since: time)
            }
            return VisionPlayFrame(trigger: trigger, pointer: nil)
        }
    }

    private func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }
}
