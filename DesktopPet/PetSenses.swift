import AVFoundation
import Observation
import UIKit
import Vision

enum PetStimulus: Sendable {
    case faceReturned, faceLost, searching
    case wave, thumbsUp, heart
    case shake, faceDown, faceUp, pickedUp
    case clap, doubleClap, blow, musicStarted, musicStopped
}

enum PetCameraStatus: Equatable {
    case inactive, starting, active, denied, unavailable, thermal
}

@Observable @MainActor
final class PetSenses {
    var onEvent: ((PetStimulus) -> Void)?
    private(set) var isFaceDown = false
    private(set) var cameraStatus: PetCameraStatus = .inactive
    private(set) var motionUnavailable = false
    @ObservationIgnored private(set) var gaze = CGPoint.zero

    var handTarget: CGPoint? {
        guard let handSeenAt, ProcessInfo.processInfo.systemUptime - handSeenAt <= handHoldDuration else { return nil }
        return handGaze
    }

    var faceTarget: CGPoint? {
        guard let faceSeenAt, ProcessInfo.processInfo.systemUptime - faceSeenAt <= 0.3 else { return nil }
        return CGPoint(x: faceGaze.x / 38, y: faceGaze.y / 21.5)
    }

    @ObservationIgnored private let camera = CameraSense()
    @ObservationIgnored private let motion = MotionSense()
    @ObservationIgnored private var active = false
    @ObservationIgnored private var eyeTracking = false
    @ObservationIgnored private var handGestures = false
    @ObservationIgnored private var suppressCamera = false
    @ObservationIgnored private var motionRunning = false
    @ObservationIgnored private var orientation: UIInterfaceOrientation = .portrait
    @ObservationIgnored private var cameraConfiguration: CameraConfiguration?
    @ObservationIgnored private var cameraGeneration = 0
    @ObservationIgnored private var permissionRequest: Task<Void, Never>?
    @ObservationIgnored private var thermalMonitor: Task<Void, Never>?
    @ObservationIgnored private var handGaze = CGPoint.zero
    @ObservationIgnored private var handSeenAt: TimeInterval?
    private let handHoldDuration: TimeInterval = 0.28
    @ObservationIgnored private var faceGaze = CGPoint.zero
    @ObservationIgnored private var motionGaze = CGPoint.zero
    @ObservationIgnored private var faceSeenAt: TimeInterval?
    @ObservationIgnored private var faceMissingSince: TimeInterval?
    @ObservationIgnored private var nextSearchAt: TimeInterval?

    init() {
        motion.onSample = { [weak self] tilt, event in
            self?.receiveMotion(tilt: tilt, event: event)
        }
        motion.onUnavailable = { [weak self] in
            guard let self else { return }
            self.motionUnavailable = true
            self.receiveMotion(tilt: .zero, event: self.isFaceDown ? .faceUp : nil)
        }
    }

    func configure(active: Bool, eyeTracking: Bool, handGestures: Bool, motionEnabled: Bool,
                   suppressCamera: Bool = false) {
        self.active = active
        if self.eyeTracking != eyeTracking { resetFaceTracking() }
        self.eyeTracking = eyeTracking
        self.handGestures = handGestures
        self.suppressCamera = suppressCamera

        let shouldRunMotion = active && motionEnabled && motion.isAvailable
        if !motionEnabled { motionUnavailable = false }
        if motionEnabled && !motion.isAvailable { motionUnavailable = true }
        if shouldRunMotion != motionRunning {
            motionRunning = shouldRunMotion
            if shouldRunMotion {
                motionUnavailable = false
                motion.start()
            } else {
                motion.stop(keepFaceDown: motionEnabled)
                motionGaze = .zero
                updateGaze()
            }
        }
        if !motionEnabled && isFaceDown {
            motion.stop(keepFaceDown: false)
            isFaceDown = false
        }

        updateThermalMonitor()
        updateCamera()
    }

    func setOrientation(_ orientation: UIInterfaceOrientation) {
        guard orientation != .unknown, orientation != self.orientation else { return }
        self.orientation = orientation
        motion.orientation = orientation
        resetHandTracking()
        resetFaceTracking()
        updateCamera()
    }

    func requestCameraPermission() {
        guard !suppressCamera, permissionRequest == nil,
              AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            updateCamera()
            return
        }
        permissionRequest = Task { [weak self] in
            _ = await AVCaptureDevice.requestAccess(for: .video)
            guard let self else { return }
            self.permissionRequest = nil
            self.updateCamera()
        }
    }

    private func updateThermalMonitor() {
        guard active, !suppressCamera, eyeTracking || handGestures else {
            thermalMonitor?.cancel()
            thermalMonitor = nil
            return
        }
        guard thermalMonitor == nil else { return }
        thermalMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self else { return }
                self.updateCamera()
            }
        }
    }

    private func updateCamera() {
        guard eyeTracking || handGestures else {
            stopCamera(status: .inactive)
            return
        }

        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        if authorization == .denied || authorization == .restricted {
            stopCamera(status: .denied)
            return
        }
        guard active, !isFaceDown, !suppressCamera else {
            stopCamera(status: .inactive)
            return
        }
        let thermalState = ProcessInfo.processInfo.thermalState
        if thermalState == .serious || thermalState == .critical {
            stopCamera(status: .thermal)
            return
        }
        if authorization == .notDetermined {
            stopCamera(status: .starting)
            if permissionRequest == nil { requestCameraPermission() }
            return
        }
        guard authorization == .authorized else {
            stopCamera(status: .unavailable)
            return
        }

        let configuration = CameraConfiguration(
            orientation: orientation,
            tracksFaces: eyeTracking,
            recognizesGestures: handGestures
        )
        guard configuration != cameraConfiguration else { return }
        if cameraConfiguration == nil { cameraStatus = .starting }
        cameraConfiguration = configuration
        cameraGeneration += 1
        let generation = cameraGeneration
        camera.configure(configuration) { [weak self] update in
            guard let self, self.cameraGeneration == generation else { return }
            switch update {
            case .availability(let available):
                self.cameraStatus = available ? .active : .unavailable
                if !available {
                    self.resetHandTracking()
                    self.resetFaceTracking()
                }
            case .frame(let hand, let face, let checkedFace, let event, let timestamp):
                if let hand { self.receiveHand(hand, at: timestamp) }
                if checkedFace { self.receiveFace(face, at: timestamp) }
                if let event, self.handGestures { self.onEvent?(event) }
            }
        }
    }

    private func stopCamera(status: PetCameraStatus) {
        if cameraConfiguration != nil {
            cameraConfiguration = nil
            cameraGeneration += 1
            camera.stop()
            resetHandTracking()
            resetFaceTracking()
        }
        cameraStatus = status
    }

    private func receiveHand(_ center: CGPoint, at timestamp: TimeInterval) {
        // Vision gives an unmirrored, bottom-left origin. Move like a selfie preview.
        let target = CGPoint(x: max(-1, min(1, (0.5 - center.x) / 0.40)),
                             y: max(-1, min(1, (0.5 - center.y) / 0.40)))
        if let previous = handSeenAt, timestamp - previous <= handHoldDuration {
            handGaze.x += (target.x - handGaze.x) * 0.65
            handGaze.y += (target.y - handGaze.y) * 0.65
        } else {
            handGaze = target
        }
        handSeenAt = timestamp
    }

    private func resetHandTracking() {
        handSeenAt = nil
        handGaze = .zero
    }

    private func receiveMotion(tilt: CGPoint, event: PetStimulus?) {
        motionGaze = tilt
        updateGaze()
        guard let event else { return }
        switch event {
        case .faceDown, .faceUp:
            isFaceDown = motion.isFaceDown
            updateCamera()
        default:
            break
        }
        onEvent?(event)
    }

    private func receiveFace(_ center: CGPoint?, at timestamp: TimeInterval) {
        if let center {
            let previous = faceSeenAt
            faceSeenAt = timestamp
            faceMissingSince = nil
            nextSearchAt = nil
            setFaceGaze(CGPoint(x: (0.5 - center.x) * 76, y: (0.5 - center.y) * 43))
            if let previous, timestamp - previous >= 10 { onEvent?(.faceReturned) }
            return
        }

        setFaceGaze(.zero)
        let missingSince = faceMissingSince ?? timestamp
        faceMissingSince = missingSince
        guard timestamp - missingSince >= 5 else { return }
        if let nextSearchAt {
            if timestamp >= nextSearchAt {
                self.nextSearchAt = timestamp + 6
                onEvent?(.searching)
            }
        } else {
            nextSearchAt = timestamp + 6
            onEvent?(.faceLost)
        }
    }

    private func resetFaceTracking() {
        faceSeenAt = nil
        faceMissingSince = nil
        nextSearchAt = nil
        faceGaze = .zero
        updateGaze()
    }

    private func setFaceGaze(_ target: CGPoint) {
        faceGaze.x += (target.x - faceGaze.x) * 0.29
        faceGaze.y += (target.y - faceGaze.y) * 0.29
        updateGaze()
    }

    private func updateGaze() {
        gaze = CGPoint(x: max(-46, min(46, faceGaze.x + motionGaze.x)),
                       y: max(-26, min(26, faceGaze.y + motionGaze.y)))
    }
}

private nonisolated struct CameraConfiguration: Equatable, Sendable {
    var orientation: UIInterfaceOrientation
    var tracksFaces: Bool
    var recognizesGestures: Bool

    // The orientation API accounts for the physical sensor mount on different iPhones.
    var videoOrientation: AVCaptureVideoOrientation {
        switch orientation {
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .portraitUpsideDown: .portraitUpsideDown
        default: .portrait
        }
    }
}

private nonisolated enum CameraUpdate: Sendable {
    case availability(Bool)
    case frame(hand: CGPoint?, face: CGPoint?, checkedFace: Bool, event: PetStimulus?, timestamp: TimeInterval)
}

// Capture configuration and all frame processing share this private serial queue.
private nonisolated final class CameraSense: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.haozi.desktoppet.camera", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var configuration: CameraConfiguration?
    private var onUpdate: (@MainActor @Sendable (CameraUpdate) -> Void)?
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let handRequest = VNDetectHumanHandPoseRequest()
    private var framesUntilFace = 0
    private var gestures = GestureDetector()
    private var handTracker = HandTracker()

    func configure(_ configuration: CameraConfiguration, onUpdate: @escaping @MainActor @Sendable (CameraUpdate) -> Void) {
        queue.async {
            if self.configuration?.orientation != configuration.orientation ||
                self.configuration?.recognizesGestures != configuration.recognizesGestures {
                self.gestures = GestureDetector()
            }
            if self.configuration?.orientation != configuration.orientation {
                self.handTracker = HandTracker()
            }
            self.framesUntilFace = 0
            self.configuration = configuration
            self.onUpdate = onUpdate
            let session = self.session ?? self.prepareSession()
            if let connection = self.output?.connection(with: .video),
               connection.isVideoOrientationSupported,
               connection.videoOrientation != configuration.videoOrientation {
                connection.videoOrientation = configuration.videoOrientation
            }
            if let session, !session.isRunning { session.startRunning() }
            self.report(.availability(session?.isRunning == true))
        }
    }

    func stop() {
        queue.async {
            self.configuration = nil
            self.onUpdate = nil
            if let session = self.session, session.isRunning { session.stopRunning() }
        }
    }

    private func prepareSession() -> AVCaptureSession? {
        dispatchPrecondition(condition: .onQueue(queue))
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
            ?? AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera],
                                                mediaType: .video, position: .front).devices.first
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return nil
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return nil
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()

        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 15 && $0.maxFrameRate >= 15 }),
           (try? device.lockForConfiguration()) != nil {
            let frameDuration = CMTime(value: 1, timescale: 15)
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
        }
        handRequest.maximumHandCount = 2
        self.session = session
        self.output = output
        return session
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let configuration else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up)
        // Give hand motion every frame and sample the slower-changing face less often.
        let checkFace = configuration.tracksFaces && framesUntilFace == 0
        framesUntilFace = checkFace ? 2 : max(0, framesUntilFace - 1)
        let requests: [VNRequest] = checkFace ? [handRequest, faceRequest] : [handRequest]
        guard (try? handler.perform(requests)) != nil else { return }

        let face = checkFace
            ? faceRequest.results?.max(by: { $0.boundingBox.area < $1.boundingBox.area })?.boundingBox
            : nil
        let faceCenter = face.map { CGPoint(x: $0.midX, y: $0.midY) }
        let handPoints = (handRequest.results ?? []).compactMap { try? $0.recognizedPoints(.all) }
        let handCenter = handTracker.update(handPoints, at: now)
        let event = configuration.recognizesGestures ? gestures.update(handPoints, at: now) : nil
        report(.frame(hand: handCenter, face: faceCenter, checkedFace: checkFace, event: event, timestamp: now))
    }

    private func report(_ update: CameraUpdate) {
        guard let onUpdate else { return }
        Task { @MainActor in onUpdate(update) }
    }
}

private typealias HandPoints = [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]

private nonisolated struct HandTracker {
    private var previous: CGPoint?
    private var lastSeenAt: TimeInterval = -.infinity

    mutating func update(_ hands: [HandPoints], at time: TimeInterval) -> CGPoint? {
        let candidates = hands.compactMap(Self.palmCenter)
        let selected: CGPoint?
        if let previous, time - lastSeenAt <= 0.28 {
            selected = candidates.min { $0.distance(to: previous) < $1.distance(to: previous) }
        } else {
            selected = candidates.first
        }
        if let selected {
            previous = selected
            lastSeenAt = time
        }
        return selected
    }

    private static func palmCenter(_ points: HandPoints) -> CGPoint? {
        let joints: [VNHumanHandPoseObservation.JointName] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let palm = joints.compactMap { points[$0] }.filter { $0.confidence >= 0.35 }
        guard palm.count >= 2 else { return nil }
        let sum = palm.reduce(into: CGPoint.zero) { center, joint in
            center.x += joint.x
            center.y += joint.y
        }
        return CGPoint(x: sum.x / CGFloat(palm.count), y: sum.y / CGFloat(palm.count))
    }
}

private extension CGRect {
    nonisolated var area: CGFloat { width * height }
}

private nonisolated struct GestureDetector {
    private enum Gesture {
        case wave, thumbsUp, heart

        var event: PetStimulus {
            switch self {
            case .wave: .wave
            case .thumbsUp: .thumbsUp
            case .heart: .heart
            }
        }
    }

    private var candidate: Gesture?
    private var consecutiveFrames = 0
    private var lastReported: Gesture?
    private var lastReportedAt: TimeInterval = 0
    private var wave = WaveDetector()

    mutating func update(_ points: [HandPoints], at time: TimeInterval) -> PetStimulus? {
        let hands = points.compactMap(Hand.init)
        let waving = wave.update(hands.filter(\.isOpen), at: time)
        let detected: Gesture?
        if hands.count == 2, hands[0].formsHeart(with: hands[1]) {
            detected = .heart
        } else if hands.contains(where: \.isThumbsUp) {
            detected = .thumbsUp
        } else {
            detected = waving ? .wave : nil
        }

        if detected == candidate {
            consecutiveFrames += 1
        } else {
            candidate = detected
            consecutiveFrames = 1
        }
        guard consecutiveFrames >= 3 else { return nil }
        guard let detected else {
            lastReported = nil
            return nil
        }
        guard detected != lastReported, time - lastReportedAt >= 1.5 else { return nil }
        lastReported = detected
        lastReportedAt = time
        return detected.event
    }

    private struct Hand {
        private let points: HandPoints
        let wrist: CGPoint
        let scale: CGFloat

        init?(_ points: HandPoints) {
            guard let wrist = points[.wrist], wrist.confidence >= 0.35,
                  let knuckle = points[.middleMCP], knuckle.confidence >= 0.35 else { return nil }
            self.points = points
            self.wrist = wrist.location
            scale = wrist.location.distance(to: knuckle.location)
            guard scale >= 0.025 else { return nil }
        }

        private func point(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let value = points[joint], value.confidence >= 0.35 else { return nil }
            return value.location
        }

        private static let fingers: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
            (.indexTip, .indexPIP), (.middleTip, .middlePIP), (.ringTip, .ringPIP), (.littleTip, .littlePIP)
        ]

        var isOpen: Bool {
            Self.fingers.allSatisfy { tip, joint in
                guard let tip = point(tip), let joint = point(joint) else { return false }
                return wrist.distance(to: tip) > wrist.distance(to: joint) + scale * 0.23
            }
        }

        var isThumbsUp: Bool {
            guard let thumb = point(.thumbTip), let thumbJoint = point(.thumbMP),
                  thumb.y - thumbJoint.y > scale * 0.34 else { return false }
            return Self.fingers.allSatisfy { tip, joint in
                guard let tip = point(tip), let joint = point(joint) else { return false }
                return thumb.y - tip.y > scale * 0.18 &&
                    wrist.distance(to: tip) < wrist.distance(to: joint) + scale * 0.14
            }
        }

        func formsHeart(with other: Hand) -> Bool {
            guard let index = point(.indexTip), let otherIndex = other.point(.indexTip),
                  let thumb = point(.thumbTip), let otherThumb = other.point(.thumbTip) else { return false }
            let size = (scale + other.scale) * 0.5
            let indexY = (index.y + otherIndex.y) * 0.5
            let thumbY = (thumb.y + otherThumb.y) * 0.5
            return index.distance(to: otherIndex) < size * 0.62 &&
                thumb.distance(to: otherThumb) < size * 0.58 &&
                indexY - thumbY > size * 0.30 &&
                wrist.distance(to: other.wrist) > size
        }
    }

    private struct WaveDetector {
        private var anchorX: CGFloat?
        private var lastWrist: CGPoint?
        private var direction = 0
        private var reversals: [TimeInterval] = []
        private var recognizedUntil: TimeInterval = 0

        mutating func update(_ openHands: [Hand], at time: TimeInterval) -> Bool {
            guard let first = openHands.first else {
                self = Self()
                return false
            }
            let hand: Hand
            if let lastWrist {
                hand = openHands.min {
                    $0.wrist.distance(to: lastWrist) < $1.wrist.distance(to: lastWrist)
                } ?? first
                if lastWrist.distance(to: hand.wrist) > 0.30 { self = Self() }
            } else {
                hand = first
            }
            lastWrist = hand.wrist

            let current = hand.wrist.x
            let anchor = anchorX ?? current
            let delta = current - anchor
            let threshold = max(0.038, hand.scale * 0.32)
            reversals.removeAll { time - $0 > 1.2 }
            if abs(delta) >= threshold {
                let next = delta > 0 ? 1 : -1
                if direction != 0, direction != next {
                    reversals.append(time)
                    if reversals.count >= 2 {
                        recognizedUntil = time + 0.45
                        reversals.removeAll()
                    }
                }
                direction = next
                anchorX = current
            } else if anchorX == nil {
                anchorX = current
            }
            return time < recognizedUntil
        }
    }
}

private extension CGPoint {
    nonisolated func distance(to other: Self) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
