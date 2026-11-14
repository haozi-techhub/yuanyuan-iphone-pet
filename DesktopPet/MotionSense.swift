import CoreMotion
import UIKit

@MainActor
final class MotionSense {
    var orientation: UIInterfaceOrientation = .portrait
    var onSample: ((CGPoint, PetStimulus?) -> Void)?
    var onUnavailable: (() -> Void)?
    private(set) var isFaceDown = false
    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    private let manager = CMMotionManager()
    private var sampling: Task<Void, Never>?
    private var lastTimestamp: TimeInterval?
    private var faceDownSince: TimeInterval?
    private var stillSince: TimeInterval?
    private var lastStillAt: TimeInterval?
    private var shakePeaks: [TimeInterval] = []
    private var aboveShakeThreshold = false
    private var ignoreMovementUntil: TimeInterval = 0
    private var tilt = CGPoint.zero
    private var velocity = CGPoint.zero

    func start() {
        guard sampling == nil, isAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.readSample(initialDeadline: deadline) == true else { return }
                do {
                    try await Task.sleep(for: .milliseconds(33))
                } catch {
                    return
                }
            }
        }
    }

    func stop(keepFaceDown: Bool) {
        sampling?.cancel()
        sampling = nil
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        lastTimestamp = nil
        faceDownSince = nil
        stillSince = nil
        lastStillAt = nil
        shakePeaks.removeAll()
        aboveShakeThreshold = false
        ignoreMovementUntil = 0
        tilt = .zero
        velocity = .zero
        if !keepFaceDown { isFaceDown = false }
    }

    private func readSample(initialDeadline: TimeInterval) -> Bool {
        guard let sample = manager.deviceMotion else {
            if lastTimestamp == nil, ProcessInfo.processInfo.systemUptime >= initialDeadline {
                stop(keepFaceDown: false)
                onUnavailable?()
                return false
            }
            return true
        }
        guard sample.timestamp != lastTimestamp else { return true }
        lastTimestamp = sample.timestamp
        let event = stimulus(from: sample)
        let target = isFaceDown ? .zero : screenTilt(from: sample.gravity)
        velocity.x = (velocity.x + (target.x - tilt.x) * 0.24) * 0.68
        velocity.y = (velocity.y + (target.y - tilt.y) * 0.24) * 0.68
        tilt.x += velocity.x
        tilt.y += velocity.y
        onSample?(tilt, event)
        return true
    }

    private func screenTilt(from gravity: CMAcceleration) -> CGPoint {
        let vector: (Double, Double)
        switch orientation {
        case .landscapeLeft: vector = (gravity.y, gravity.x)
        case .landscapeRight: vector = (-gravity.y, -gravity.x)
        case .portraitUpsideDown: vector = (-gravity.x, gravity.y)
        default: vector = (gravity.x, -gravity.y)
        }
        return CGPoint(x: vector.0 * 20, y: vector.1 * 13)
    }

    private func stimulus(from sample: CMDeviceMotion) -> PetStimulus? {
        let now = sample.timestamp
        let z = sample.gravity.z
        if isFaceDown {
            guard z < 0.5 else { return nil }
            isFaceDown = false
            faceDownSince = nil
            ignoreMovementUntil = now + 0.7
            return .faceUp
        }

        if z > 0.9 {
            let since = faceDownSince ?? now
            faceDownSince = since
            if now - since >= 1 {
                isFaceDown = true
                stillSince = nil
                lastStillAt = nil
                shakePeaks.removeAll()
                aboveShakeThreshold = false
                return .faceDown
            }
        } else {
            faceDownSince = nil
        }

        guard now >= ignoreMovementUntil else { return nil }
        let acceleration = sample.userAcceleration
        let strength = sqrt(acceleration.x * acceleration.x +
                            acceleration.y * acceleration.y +
                            acceleration.z * acceleration.z)
        let rotation = sample.rotationRate
        let rotationStrength = sqrt(rotation.x * rotation.x +
                                    rotation.y * rotation.y +
                                    rotation.z * rotation.z)
        let pickedUp = pickup(at: now, acceleration: strength, rotation: rotationStrength)
        if shake(at: now, strength: strength) { return .shake }
        return pickedUp ? .pickedUp : nil
    }

    private func shake(at now: TimeInterval, strength: Double) -> Bool {
        if strength < 1.25 { aboveShakeThreshold = false }
        guard strength > 2, !aboveShakeThreshold else { return false }
        aboveShakeThreshold = true
        shakePeaks.removeAll { now - $0 > 0.6 }
        if let previous = shakePeaks.last, now - previous < 0.07 { return false }
        shakePeaks.append(now)
        guard shakePeaks.count >= 3 else { return false }
        shakePeaks.removeAll()
        ignoreMovementUntil = now + 1.5
        return true
    }

    private func pickup(at now: TimeInterval, acceleration: Double, rotation: Double) -> Bool {
        if acceleration < 0.10, rotation < 0.15 {
            if stillSince == nil { stillSince = now }
            lastStillAt = now
            return false
        }

        guard let since = stillSince, let lastStillAt else { return false }
        if acceleration > 0.5, now - lastStillAt <= 0.25, lastStillAt - since >= 30 {
            stillSince = nil
            self.lastStillAt = nil
            return true
        }
        if now - lastStillAt > 0.25 {
            stillSince = nil
            self.lastStillAt = nil
        }
        return false
    }
}
