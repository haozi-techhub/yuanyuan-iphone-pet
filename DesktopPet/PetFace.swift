import SwiftUI

struct PetFace: View {
    var pose: PetPose
    var time: TimeInterval
    var elapsed: TimeInterval
    var mouthEnabled: Bool
    var motionEnabled: Bool
    var eyeTint: Color? = nil
    var batteryLevel: Double? = nil
    var drawingSize: CGSize? = nil
    var centerOffset: CGSize = .zero

    var body: some View {
        Canvas { context, size in
            let artSize = drawingSize ?? size
            let scale = min(artSize.width / 475, artSize.height / 215)
            var face = context
            face.translateBy(x: size.width / 2 + centerOffset.width, y: size.height / 2 + centerOffset.height)
            face.scaleBy(x: scale, y: scale)

            let shiver = motionEnabled ? sin(time * 19) * 1.2 * pose.tears : 0
            let tremble = motionEnabled && pose.accent == .frost ? sin(elapsed * 42) * 3 * pose.accentOpacity : 0
            face.translateBy(x: pose.lookX + shiver + tremble, y: pose.bounce + pose.lookY)

            face.rotate(by: .degrees(Double(pose.turn) * 5))
            face.scaleBy(x: 1 - abs(pose.turn) * 0.065, y: 1)

            let effect = max(pose.stars, pose.glasses, pose.hearts, pose.spirals, pose.confetti,
                             pose.accent == .power ? pose.accentOpacity : 0)
            let pulse = motionEnabled && eyeTint == nil ? sin(time * 1.9) * 0.035 : 0
            let brightness = min(1, pose.brightness + pulse)
            let anger = Double(pose.anger)
            let eyeColor = eyeTint ?? Color(red: 1, green: 1 - 0.83 * anger, blue: 1 - 0.88 * anger)
            if motionEnabled && pose.glasses > 0 { drawGlassesStreaks(in: face) }
            drawEye(in: face, x: -76, eye: pose.left, color: eyeColor, opacity: (1 - effect) * brightness)
            drawEye(in: face, x: 76, eye: pose.right, color: eyeColor, opacity: (1 - effect) * brightness)

            if pose.cheeks > 0 { drawCheeks(in: face) }
            if pose.anger > 0 { drawAngerMark(in: face) }
            if pose.stars > 0 { drawStars(in: face) }
            if pose.hearts > 0 { drawHearts(in: face) }
            if pose.spirals > 0 { drawSpirals(in: face) }
            if pose.sleep > 0 { drawSleep(in: face) }
            if pose.notes > 0 { drawNotes(in: face) }
            if pose.accent != .none && pose.accentOpacity > 0.01 { drawAccent(in: face) }
            if pose.confetti > 0 { drawCelebration(in: face) }
            if pose.glasses > 0 { drawGlasses(in: face) }
            if mouthEnabled && pose.mouth > 0 { drawMouth(in: face) }
            drawHandsAndProps(in: face)
            if pose.tears > 0 {
                drawTear(in: face, x: -76, delay: 0)
                drawTear(in: face, x: 76, delay: 0.48)
            }
        }
        .accessibilityHidden(true)
    }

    private func drawEye(in context: GraphicsContext, x: CGFloat, eye: EyePose, color: Color, opacity: CGFloat) {
        guard opacity > 0 else { return }
        let side: CGFloat = x < 0 ? -1 : 1
        let activity = max(pose.greeting * 0.7, pose.notes, pose.cheeks * 0.5,
                           pose.accent == .laugh ? pose.accentOpacity : 0)
        let beat = motionEnabled ? sin(elapsed * 7.5 - side * 0.2) * activity : 0
        let openness = max(0, eye.height * (1 + beat * 0.09))
        let bend = min(1, max(-1, eye.curve / 85))
        let perspective = 1 + side * pose.turn * 0.095

        var layer = context
        layer.translateBy(x: x + eye.shift, y: eye.lift - beat * 2.8)
        layer.rotate(by: .radians(eye.tilt + side * beat * 0.035))
        layer.scaleBy(x: perspective, y: perspective)
        layer.opacity = opacity
        drawEyelid(in: layer, openness: openness, bend: bend,
                   widthScale: eye.width * (1 + pose.anger * 0.21),
                   strokeWeight: eye.lidWeight, color: color)
    }

    private func drawEyelid(in context: GraphicsContext, openness: CGFloat, bend: CGFloat,
                           widthScale: CGFloat, strokeWeight: CGFloat, color: Color) {
        let curvedLid = min(1, max(0, (abs(bend) - 0.35) / 0.45))
        let openLimit = 0.43 + curvedLid * 0.08
        let closedLimit = 0.19 + curvedLid * 0.13
        let closed = smoothProgress((openLimit - openness) / (openLimit - closedLimit))
        // Fill out every curved lid as it closes, including curves set by animation keyframes.
        let fullness = smoothProgress(abs(bend) / 0.30)
        let radius = strokeWeight / 2
        let closedThickness = radius * 1.08 + 3 * fullness
        let thickness = (1 - closed) * 53 * openness + closed * closedThickness
        let openWidth = 35 * widthScale
        let closedWidth = (22 + 13 * abs(bend)) * widthScale + radius * 0.85
        let halfWidth = openWidth + (closedWidth - openWidth) * closed
        let arc = 30 * bend * closed * closed * closed
        let centerY = 6 * closed * (1 - abs(bend)) + arc * 0.75
        let cornerRoundness = 0.48 * closed
        let taper = (0.09 - 0.19 * fullness) * closed

        // Bend one continuous oval. Spreading the turn across its sides lets the lids
        // taper into the tips without a separate end cap.
        func outlinePoint(at angle: CGFloat) -> (point: CGPoint, tangent: CGVector) {
            let horizontal = sin(angle)
            let vertical = cos(angle)
            let x = horizontal * (1 + cornerRoundness * vertical * vertical)
            let dx = vertical * (1 + cornerRoundness * (1 - 3 * horizontal * horizontal))
            let taperScale = 1 - taper * horizontal * horizontal
            let offset = thickness * vertical * taperScale
            let offsetRate = -thickness * horizontal * (taperScale + 2 * taper * vertical * vertical)
            let normalX = 2 * arc * x / halfWidth
            let normalScale = 1 / hypot(1, normalX)
            let normal = CGVector(dx: normalX * normalScale, dy: normalScale)
            let normalRate = (2 * arc * dx / halfWidth) * normalScale * normalScale * normalScale
            return (
                CGPoint(x: halfWidth * x + offset * normal.dx,
                        y: centerY - arc * x * x + offset * normal.dy),
                CGVector(dx: halfWidth * dx + offsetRate * normal.dx + offset * normalRate,
                         dy: -2 * arc * x * dx + offsetRate * normal.dy - offset * normalX * normalRate)
            )
        }

        let sections = 16
        let step = 2 * CGFloat.pi / CGFloat(sections)
        let handle = step / 3
        let outline = Path { path in
            let start = outlinePoint(at: 0)
            var previous = start
            path.move(to: start.point)
            for index in 1...sections {
                let next = index == sections ? start : outlinePoint(at: CGFloat(index) * step)
                path.addCurve(to: next.point,
                              control1: CGPoint(x: previous.point.x + previous.tangent.dx * handle,
                                                y: previous.point.y + previous.tangent.dy * handle),
                              control2: CGPoint(x: next.point.x - next.tangent.dx * handle,
                                                y: next.point.y - next.tangent.dy * handle))
                previous = next
            }
            path.closeSubpath()
        }
        context.fill(outline, with: .color(color))
    }

    private func drawCheeks(in context: GraphicsContext) {
        let pink = Color(hex: 0xFF83A4)
        for x in [-105.0, 105.0] {
            let bounds = CGRect(x: x - 11, y: 32, width: 22, height: 8)
            context.fill(Path(roundedRect: bounds, cornerRadius: 4), with: .color(pink.opacity(pose.cheeks * 0.47)))
        }
    }

    private func drawAngerMark(in context: GraphicsContext) {
        var mark = context
        mark.translateBy(x: PetActionGeometry.angerMark.x, y: PetActionGeometry.angerMark.y)
        mark.opacity = pose.anger
        for arm in 0..<4 {
            var corner = mark
            corner.rotate(by: .degrees(Double(arm) * 90 + 14))
            let stroke = Path { path in
                path.move(to: CGPoint(x: 4, y: 15))
                path.addQuadCurve(to: CGPoint(x: 15, y: 4), control: CGPoint(x: 4, y: 4))
            }
            corner.stroke(stroke, with: .color(Color(hex: 0xFF372C)),
                          style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
    }

    private func drawStars(in context: GraphicsContext) {
        let expansion = smoothProgress(elapsed / 0.21)
        let settle = smoothProgress((elapsed - 0.21) / 0.13)
        let scale = motionEnabled ? 0.72 + 0.40 * expansion - 0.12 * settle : 1
        let vertices = (0..<10).map { index in
            let angle = Double(index) * .pi / 5 - .pi / 2
            let radius: CGFloat = index.isMultiple(of: 2) ? 30 : 18
            return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        let star = roundedPolygon(vertices, cornerFraction: 0.44)
        let ivory = Color(hex: 0xFFF6D0)
        for x in [-76.0, 76.0] {
            var eye = context
            eye.translateBy(x: x, y: 0)
            eye.scaleBy(x: scale, y: scale)
            eye.opacity = pose.stars
            var glow = eye
            glow.addFilter(.blur(radius: 10))
            glow.fill(star, with: .color(Color(hex: 0xFFBE58).opacity(0.31)))
            eye.fill(star, with: .color(ivory))
        }
    }

    private func roundedPolygon(_ vertices: [CGPoint], cornerFraction: CGFloat) -> Path {
        guard let first = vertices.first, let last = vertices.last, vertices.count > 2 else { return Path() }
        func toward(_ end: CGPoint, from start: CGPoint, by amount: CGFloat) -> CGPoint {
            CGPoint(x: start.x + (end.x - start.x) * amount,
                    y: start.y + (end.y - start.y) * amount)
        }

        return Path { path in
            path.move(to: toward(last, from: first, by: cornerFraction))
            for index in vertices.indices {
                let vertex = vertices[index]
                let previous = vertices[(index + vertices.count - 1) % vertices.count]
                let next = vertices[(index + 1) % vertices.count]
                let start = toward(previous, from: vertex, by: cornerFraction)
                let end = toward(next, from: vertex, by: cornerFraction)
                let incoming = toward(vertex, from: start, by: 0.50)
                let outgoing = toward(vertex, from: end, by: 0.50)
                let midpoint = toward(outgoing, from: incoming, by: 0.50)
                if index > 0 { path.addLine(to: start) }
                // Both handles start on the straight edge so each corner bends in gradually.
                path.addCurve(to: midpoint, control1: toward(vertex, from: start, by: 0.28),
                              control2: incoming)
                path.addCurve(to: end, control1: outgoing,
                              control2: toward(vertex, from: end, by: 0.28))
            }
            path.closeSubpath()
        }
    }

    private func drawHearts(in context: GraphicsContext) {
        let scale = motionEnabled ? 1 + 0.08 * sin(elapsed * 11) : 1
        for x in [-76.0, 76.0] {
            var eye = context
            eye.translateBy(x: x, y: -5)
            eye.scaleBy(x: scale, y: scale)
            eye.opacity = pose.hearts
            fillGlowing(heartShape, color: Color(hex: 0xFF76B2), in: eye)
        }
    }

    private var heartShape: Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: -13))
            path.addCurve(to: CGPoint(x: 34, y: -9), control1: CGPoint(x: 13, y: -13), control2: CGPoint(x: 34, y: -39))
            path.addCurve(to: CGPoint(x: 0, y: 29), control1: CGPoint(x: 34, y: 9), control2: CGPoint(x: 11, y: 29))
            path.addCurve(to: CGPoint(x: -34, y: -9), control1: CGPoint(x: -11, y: 29), control2: CGPoint(x: -34, y: 9))
            path.addCurve(to: CGPoint(x: 0, y: -13), control1: CGPoint(x: -34, y: -39), control2: CGPoint(x: -13, y: -13))
            path.closeSubpath()
        }
    }

    private func drawSpirals(in context: GraphicsContext) {
        let rotation = motionEnabled ? elapsed * 2.4 : 0
        let samples = (0...28).map { index in
            let progress = Double(index) / 28
            let angle = progress * .pi * 3.3
            let radius = progress * 33
            return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        let spiral = Path { path in
            path.move(to: samples[0])
            for index in 1..<(samples.count - 1) {
                let point = samples[index]
                let next = samples[index + 1]
                let midpoint = CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2)
                path.addQuadCurve(to: midpoint, control: point)
            }
            let end = samples[samples.count - 1]
            let previous = samples[samples.count - 2]
            path.addQuadCurve(to: end, control: previous)
        }
        for x in [-76.0, 76.0] {
            var eye = context
            eye.translateBy(x: x, y: 0)
            eye.rotate(by: .radians(x < 0 ? rotation : -rotation))
            eye.stroke(spiral, with: .color(Color(hex: 0xBFD9FF).opacity(pose.spirals)),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawSleep(in context: GraphicsContext) {
        for index in 0..<3 {
            let step = Double(index)
            let drift = motionEnabled ? sin(elapsed * 3 - step * 0.6) * 4 : 0
            let letter = Text("z")
                .font(.system(size: 15 + step * 5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(hex: 0xC9B6FF).opacity(pose.sleep * (0.63 + step * 0.14)))
            context.draw(letter, at: CGPoint(x: 112 + step * 22, y: -26 - step * 14 + drift))
        }
    }

    private func drawAccent(in context: GraphicsContext) {
        let time = motionEnabled ? elapsed : 0.95
        let strength = pose.accentOpacity

        func icon(_ name: String, at point: CGPoint, size: CGFloat, color: Int, alpha: CGFloat = 1) {
            drawProp(name, at: point, size: size, color: color, opacity: strength * alpha, in: context)
        }

        switch pose.accent {
        case .none, .handHeart, .thumbsUp, .maracas, .charging, .marchGuitar:
            break
        case .laugh:
            for side in [-1.0, 1.0] {
                let bounce = abs(sin(time * 12)) * 8
                icon("sparkle", at: CGPoint(x: side * 131, y: -31 - bounce), size: 23, color: 0xFFDA8B)
            }
        case .wink:
            icon("sparkle", at: CGPoint(x: -131, y: -35), size: 32, color: 0xFFE2A2)
        case .listen:
            let mint = Color(hex: 0x8FE9DB)
            let breath = motionEnabled ? (1 - cos(time * 2.1)) / 2 : 0.5
            for index in 0..<2 {
                let step = Double(index)
                let x = 133 + step * 10 + breath * 3
                let halfHeight = 11 + step * 7
                let wave = Path { path in
                    path.move(to: CGPoint(x: x, y: -13 - halfHeight))
                    path.addQuadCurve(to: CGPoint(x: x, y: -13 + halfHeight),
                                      control: CGPoint(x: x + 10 + step * 3, y: -13))
                }
                let opacity = strength * (0.48 + 0.24 * breath - step * 0.12)
                context.stroke(wave, with: .color(mint.opacity(opacity)),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
        case .thought:
            for index in 0..<3 {
                let step = Double(index)
                let pulse = PetActionGeometry.thoughtPulse(at: time, index: index, motionEnabled: motionEnabled)
                icon("circle.fill", at: CGPoint(x: 126 + 18 * step, y: -48 - 7 * step),
                     size: 8 + 5 * pulse, color: 0xD6C9FF, alpha: 0.58 + 0.42 * pulse)
            }
        case .question:
            icon("questionmark", at: CGPoint(x: 122, y: -52), size: 39, color: 0xF1C9FF)
            icon("questionmark", at: CGPoint(x: 157, y: -25), size: 23, color: 0xB498FF, alpha: 0.84)
        case .peek:
            let right = smoothProgress(0.5 - pose.lookX / 64)
            icon("sparkle", at: CGPoint(x: 133, y: -47), size: 23, color: 0xB5FFD9, alpha: right)
            icon("sparkle", at: CGPoint(x: -133, y: -47), size: 23, color: 0xB5FFD9, alpha: 1 - right)
        case .yawn:
            icon("moon.stars.fill", at: CGPoint(x: 139, y: -45), size: 39, color: 0xD2C2FF)
        case .kiss:
            for index in 0..<3 {
                let step = Double(index)
                let travel = PetActionGeometry.kissProgress(at: time - step * 0.13)
                let visibility = PetActionGeometry.kissVisibility(at: travel, motionEnabled: motionEnabled)
                icon("heart.fill", at: PetActionGeometry.kissPosition(progress: travel),
                     size: 26 - step * 4, color: 0xFF78B6, alpha: visibility * (1 - step * 0.11))
            }
        case .hungry:
            icon("carrot.fill", at: CGPoint(x: 140, y: -26 + sin(time * 5) * 5), size: 45, color: 0xFFAF65)
            icon("sparkle", at: CGPoint(x: 172, y: -52), size: 17, color: 0xFFE4B4)
        case .crumbs:
            for index in 0..<6 {
                let step = Double(index)
                let travel = (time * 1.75 + step * 0.16).truncatingRemainder(dividingBy: 1)
                let visibility = PetActionGeometry.particleVisibility(at: travel, fadeIn: 0.12, fadeOut: 0.28)
                let direction = index.isMultiple(of: 2) ? -1.0 : 1.0
                icon("circle.fill", at: CGPoint(x: direction * (19 + 43 * travel),
                                               y: 52 - sin(travel * .pi) * (18 + step * 2)),
                     size: 6 + step.truncatingRemainder(dividingBy: 3), color: 0xFFC27D,
                     alpha: visibility * (1 - travel * 0.65))
            }
        case .bubbles:
            for index in 0..<4 {
                let step = Double(index)
                let travel = PetActionGeometry.bubbleProgress(at: time - step * 0.22)
                var center = PetActionGeometry.bubblePosition(progress: travel)
                center.y += sin(step * 2) * 8
                let radius = 9 + travel * 14 - step
                let alpha = strength * PetActionGeometry.bubbleVisibility(at: travel)
                let bounds = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                let bubble = Path(ellipseIn: bounds)
                context.fill(bubble, with: .color(Color(hex: 0x719AFF).opacity(alpha * 0.12)))
                context.stroke(bubble, with: .linearGradient(
                    Gradient(colors: [Color(hex: 0xB5F8FF).opacity(alpha), Color(hex: 0xBBA1FF).opacity(alpha * 0.65)]),
                    startPoint: CGPoint(x: bounds.minX, y: bounds.minY),
                    endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)
                ), lineWidth: 2.5)
            }
        case .frost:
            for index in 0..<5 {
                let step = Double(index)
                let drift = (time * 0.43 + step * 0.2).truncatingRemainder(dividingBy: 1)
                let visibility = PetActionGeometry.particleVisibility(at: drift, fadeIn: 0.12, fadeOut: 0.20)
                icon("snowflake", at: CGPoint(x: -154 + step * 77 + sin(drift * .pi * 2) * 9, y: -68 + drift * 123),
                     size: 13 + step.truncatingRemainder(dividingBy: 3) * 4, color: 0xAAEEFF,
                     alpha: visibility * (0.85 - drift * 0.32))
            }
        case .dance:
            for side in [-1.0, 1.0] {
                let beat = sin(time * 11 + side)
                icon(side < 0 ? "music.note" : "music.quarternote.3",
                     at: CGPoint(x: side * 142, y: -25 - beat * 13), size: 29 + beat * 4,
                     color: side < 0 ? 0xF9A1FF : 0x91FFF1)
            }
        case .power:
            let bolt = roundedPolygon([CGPoint(x: 7, y: -31), CGPoint(x: -23, y: 2),
                                       CGPoint(x: -3, y: 2), CGPoint(x: -7, y: 31),
                                      CGPoint(x: 23, y: -3), CGPoint(x: 3, y: -3)], cornerFraction: 0.40)
            let scale = 1 + sin(time * 10) * 0.06
            for x in [-76.0, 76.0] {
                var eye = context
                eye.translateBy(x: x, y: -4)
                eye.scaleBy(x: scale, y: scale)
                eye.fill(bolt, with: .color(Color(hex: 0xCFE3FF).opacity(strength)))
            }
            icon("battery.100percent", at: CGPoint(x: 0, y: 64), size: 30, color: 0xA9CCF5)
        }
    }

    private func drawHandsAndProps(in context: GraphicsContext) {
        let time = motionEnabled ? elapsed : 0.9

        if pose.greeting > 0.01 {
            let reach = pose.greeting
            let wave = PetActionGeometry.wave(at: time) * 24
            let palm = PetActionGeometry.greetingPalm(reach: reach)
            drawHand(in: context, at: palm, angle: -14 + wave, strength: reach)
            for index in 0..<2 {
                let x = 167 + Double(index) * 10
                let arc = Path { path in
                    path.move(to: CGPoint(x: x, y: -25))
                    path.addQuadCurve(to: CGPoint(x: x + 6, y: -14),
                                      control: CGPoint(x: x + 6, y: -22))
                }
                context.stroke(arc, with: .color(Color(hex: 0xB1FFF1).opacity(reach * 0.72)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }

        let reach = pose.accentOpacity
        guard reach > 0.01 else { return }
        let lower = (1 - reach) * 46
        switch pose.accent {
        case .handHeart:
            let lift = PetActionGeometry.heartLift(at: time, motionEnabled: motionEnabled)
            let pulse = motionEnabled ? 1 + sin(time * 10) * 0.10 : 1
            let heartY = PetActionGeometry.handHeart(reach: reach, lift: lift).y
            drawProp("heart.fill", at: CGPoint(x: 0, y: heartY), size: (43 + lift * 11) * pulse,
                     color: 0xFF79B2, opacity: reach, in: context)
            for side in [-1.0, 1.0] {
                drawProp("sparkle", at: CGPoint(x: side * (28 + lift * 15), y: heartY - 9),
                         size: 12, color: 0xFFD6E9, opacity: reach * lift * 0.85, in: context)
            }
            for side in [-1.0, 1.0] {
                let palm = CGPoint(x: side * (35 + (1 - reach) * 36), y: 63 + lower)
                drawHand(in: context, at: palm, angle: -side * 44, mirrored: side < 0, strength: reach)
            }
        case .thumbsUp:
            for side in [-1.0, 1.0] {
                var hand = context
                hand.translateBy(x: side * 134, y: 59 + lower)
                hand.rotate(by: .degrees(side * -12))
                hand.scaleBy(x: side, y: 1)
                drawProp("hand.thumbsup.fill", at: .zero, size: 50, color: 0xFFF4E2, opacity: reach, in: hand)
            }
        case .crumbs:
            let bite = smoothProgress((time - 0.80) / 0.55)
            let x = 102 - 80 * reach + 28 * bite + (motionEnabled ? sin(time * 15) * 4 : 0)
            let y = 64 + lower - 8 * reach
            drawHand(in: context, at: CGPoint(x: x + 19, y: y + 8), angle: -36, gripping: true, strength: reach)
            drawApple(in: context, at: CGPoint(x: x, y: y - 9), bite: bite, opacity: reach)
        case .bubbles:
            let x = 93 - 34 * reach
            let y = 65 + lower
            let ring = CGPoint(x: x - 22, y: y - 28)
            let handle = Path { path in
                path.move(to: CGPoint(x: ring.x + 7, y: ring.y + 9))
                path.addLine(to: CGPoint(x: x + 5, y: y + 6))
            }
            let blue = Color(hex: 0x77E4E9).opacity(reach)
            context.stroke(handle, with: .color(blue), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            context.stroke(Path(ellipseIn: CGRect(x: ring.x - 11, y: ring.y - 11, width: 22, height: 22)),
                           with: .color(blue), lineWidth: 3.5)
            drawHand(in: context, at: CGPoint(x: x + 4, y: y), angle: -36, gripping: true, strength: reach)
        case .charging:
            drawCharging(in: context, strength: reach)
        case .marchGuitar:
            drawMarchGuitar(in: context, strength: reach)
        case .maracas:
            for side in [-1.0, 1.0] {
                let shake = sin(time * 26 + side * 1.4)
                let x = side * 131
                let y = 48 + shake * 10 + lower
                var shaker = context
                shaker.translateBy(x: x, y: y)
                shaker.rotate(by: .degrees(side * (24 + shake * 23)))
                drawMaraca(in: shaker, color: Color(hex: side < 0 ? 0xFF986A : 0x68EDCF), opacity: reach)
                drawHand(in: shaker, at: CGPoint(x: 0, y: 14), angle: 0, mirrored: side < 0,
                         gripping: true, strength: reach)
            }
        default:
            break
        }
    }

    private func drawMarchGuitar(in context: GraphicsContext, strength: CGFloat) {
        let beat = motionEnabled ? PetPose.marchBeat(at: elapsed) : 0
        let rock = sin(beat * .pi)
        let stroke = motionEnabled ? sin((beat - 0.08) * 2 * .pi) : 0
        var guitar = context
        guitar.opacity *= strength
        guitar.translateBy(x: -3, y: 49 + rock * 2)
        guitar.rotate(by: .degrees(-14 + rock * 4))

        let outline = Path { path in
            path.move(to: CGPoint(x: -13, y: -6))
            path.addLine(to: CGPoint(x: 37, y: -6))
            path.addQuadCurve(to: CGPoint(x: 49, y: -13), control: CGPoint(x: 45, y: -12))
            path.addQuadCurve(to: CGPoint(x: 64, y: -10), control: CGPoint(x: 60, y: -18))
            path.addQuadCurve(to: CGPoint(x: 60, y: 7), control: CGPoint(x: 70, y: 4))
            path.addQuadCurve(to: CGPoint(x: 38, y: 5), control: CGPoint(x: 50, y: 10))
            path.addLine(to: CGPoint(x: -13, y: 5))
            path.addCurve(to: CGPoint(x: -24, y: 25),
                          control1: CGPoint(x: -1, y: 15), control2: CGPoint(x: -11, y: 25))
            path.addQuadCurve(to: CGPoint(x: -40, y: 25), control: CGPoint(x: -33, y: 24))
            path.addCurve(to: CGPoint(x: -70, y: 2),
                          control1: CGPoint(x: -60, y: 37), control2: CGPoint(x: -74, y: 22))
            path.addCurve(to: CGPoint(x: -43, y: -19),
                          control1: CGPoint(x: -72, y: -19), control2: CGPoint(x: -55, y: -29))
            path.addQuadCurve(to: CGPoint(x: -29, y: -19), control: CGPoint(x: -35, y: -16))
            path.addQuadCurve(to: CGPoint(x: -13, y: -6), control: CGPoint(x: -11, y: -26))
            path.closeSubpath()
        }
        guitar.fill(outline, with: .color(.black))
        guitar.stroke(outline, with: .color(.white),
                      style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))

        let strings = Path { path in
            for y in [-1.8, 1.8] {
                path.move(to: CGPoint(x: -52, y: y))
                path.addLine(to: CGPoint(x: 46, y: y))
            }
            path.move(to: CGPoint(x: -53, y: -5))
            path.addLine(to: CGPoint(x: -53, y: 6))
            path.move(to: CGPoint(x: 13, y: -4))
            path.addLine(to: CGPoint(x: 13, y: 4))
        }
        guitar.stroke(strings, with: .color(.white.opacity(0.8)),
                      style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

        drawGuitarPaw(in: guitar, at: CGPoint(x: 26, y: 5), angle: -21, scale: 0.8)
        drawGuitarPaw(in: guitar, at: CGPoint(x: -32, y: 9 - stroke * 8),
                      angle: 33 + stroke * 17, scale: 1)

        let accent = motionEnabled ? max(0, (stroke - 0.78) / 0.22) : 0
        if accent > 0 {
            let flick = Path { path in
                path.move(to: CGPoint(x: -50, y: -29))
                path.addLine(to: CGPoint(x: -54, y: -36))
                path.move(to: CGPoint(x: -40, y: -30))
                path.addLine(to: CGPoint(x: -39, y: -38))
            }
            guitar.stroke(flick, with: .color(.white.opacity(accent * 0.76)),
                          style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        }
    }

    private func drawGuitarPaw(in context: GraphicsContext, at point: CGPoint, angle: Double, scale: CGFloat) {
        var paw = context
        paw.translateBy(x: point.x, y: point.y)
        paw.rotate(by: .degrees(angle))
        paw.scaleBy(x: scale, y: scale)

        let mitten = Path { path in
            path.move(to: CGPoint(x: -9, y: 7))
            path.addQuadCurve(to: CGPoint(x: -11, y: -3), control: CGPoint(x: -13, y: 4))
            path.addQuadCurve(to: CGPoint(x: -3, y: -8), control: CGPoint(x: -9, y: -9))
            path.addQuadCurve(to: CGPoint(x: 5, y: -8), control: CGPoint(x: 1, y: -12))
            path.addCurve(to: CGPoint(x: 10, y: 6),
                          control1: CGPoint(x: 12, y: -7), control2: CGPoint(x: 14, y: 1))
            path.addQuadCurve(to: CGPoint(x: -9, y: 7), control: CGPoint(x: 3, y: 13))
            path.closeSubpath()
        }
        paw.fill(mitten, with: .color(.black))
        paw.stroke(mitten, with: .color(.white),
                   style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round))
    }

    private func drawCharging(in context: GraphicsContext, strength: CGFloat) {
        let time = motionEnabled ? elapsed : 1.65
        let reach = smoothProgress((time - 0.30) / 0.52)
        let plugX = 83 + (1 - reach) * 67
        let plugY = 51 + (1 - reach) * 21
        let green = Color(hex: 0x74FFCF)
        var layer = context
        layer.opacity = strength

        let cable = Path { path in
            path.move(to: CGPoint(x: plugX + 15, y: plugY))
            path.addQuadCurve(to: CGPoint(x: 206, y: 103),
                              control: CGPoint(x: plugX + 76, y: plugY - 11))
        }
        layer.stroke(cable, with: .color(green.opacity(0.46)),
                     style: StrokeStyle(lineWidth: 4, lineCap: .round))
        let connectedTime = max(0, time - 0.82)
        if connectedTime > 0 {
            let flow = motionEnabled ? (connectedTime / 0.72).truncatingRemainder(dividingBy: 1) : 0.45
            let head = 1.18 * (1 - flow)
            let intensity = PetActionGeometry.particleVisibility(at: flow, fadeIn: 0.14, fadeOut: 0.16)
            layer.stroke(cable.trimmedPath(from: min(1, max(0, head - 0.18)), to: min(1, head)),
                         with: .color(Color(hex: 0xDEFFF2).opacity(intensity)),
                         style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
        }

        let battery = CGRect(x: -59, y: 35, width: 118, height: 32)
        layer.stroke(Path(roundedRect: battery, cornerRadius: 8),
                     with: .color(green.opacity(0.92)), lineWidth: 2.7)
        layer.fill(Path(roundedRect: CGRect(x: 60, y: 45, width: 7, height: 12), cornerRadius: 2),
                   with: .color(green.opacity(0.86)))

        let phase = connectedTime.truncatingRemainder(dividingBy: 1.38)
        let reset = 1 - smoothProgress((phase - 1.04) / 0.34)
        for index in 0..<4 {
            let bar = CGRect(x: -51 + CGFloat(index) * 26, y: 42, width: 21, height: 18)
            let outline = Path(roundedRect: bar, cornerRadius: 3)
            if let batteryLevel {
                layer.fill(outline, with: .color(green.opacity(0.14)))
                let fill = min(1, max(0, batteryLevel * 4 - Double(index)))
                if fill > 0 {
                    var filledLayer = layer
                    filledLayer.clip(to: Path(CGRect(x: bar.minX, y: bar.minY,
                                                    width: bar.width * fill, height: bar.height)))
                    filledLayer.fill(outline, with: .color(green.opacity(0.92)))
                }
            } else {
                let lit = smoothProgress((phase - Double(index) * 0.23) / 0.17) * reset
                layer.fill(outline, with: .color(green.opacity(0.14 + 0.78 * lit)))
            }
        }

        let plug = Path(roundedRect: CGRect(x: plugX - 16, y: plugY - 9, width: 30, height: 18),
                        cornerRadius: 4)
        layer.fill(plug, with: .color(green))
        let contact = Path(roundedRect: CGRect(x: plugX - 21, y: plugY - 5, width: 9, height: 10),
                           cornerRadius: 2)
        layer.fill(contact, with: .color(Color(hex: 0xD6FFEA)))
        let handFade = max(0, 1 - (time - 1.01) / 0.38)
        drawHand(in: context, at: CGPoint(x: plugX + 12, y: plugY + 12 + (1 - min(1, handFade)) * 24),
                 angle: -27, gripping: true, strength: strength * min(1, handFade))
    }

    private func smoothProgress(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    private func drawHand(in context: GraphicsContext, at point: CGPoint,
                          angle: Double, mirrored: Bool = false, gripping: Bool = false, strength: CGFloat) {
        var hand = context
        hand.translateBy(x: point.x, y: point.y)
        hand.rotate(by: .degrees(angle))
        hand.scaleBy(x: mirrored ? -1 : 1, y: 1)
        let palm = gripping
            ? Path(roundedRect: CGRect(x: -15, y: -11, width: 30, height: 26), cornerRadius: 10)
            : roundedPolygon([
                CGPoint(x: -15, y: 19), CGPoint(x: -23, y: 7),
                CGPoint(x: -20, y: -7), CGPoint(x: -10, y: -2),
                CGPoint(x: -11, y: -22), CGPoint(x: -5, y: -25), CGPoint(x: -2, y: -12),
                CGPoint(x: 1, y: -28), CGPoint(x: 7, y: -27), CGPoint(x: 9, y: -12),
                CGPoint(x: 13, y: -18), CGPoint(x: 17, y: -15), CGPoint(x: 19, y: 4),
                CGPoint(x: 13, y: 19), CGPoint(x: 1, y: 23)
            ], cornerFraction: 0.45)
        let glove = Color(hex: 0xFFF5E9)
        hand.fill(palm, with: .color(glove.opacity(strength)))
        hand.stroke(palm, with: .color(Color(hex: 0x302632).opacity(strength * 0.58)),
                    style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        if gripping {
            let fingers = Path { path in
                path.move(to: CGPoint(x: 5, y: -7))
                path.addQuadCurve(to: CGPoint(x: -2, y: 6), control: CGPoint(x: -5, y: -3))
            }
            hand.stroke(fingers, with: .color(Color(hex: 0xB49994).opacity(strength)),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
    }

    private func drawProp(_ symbol: String, at point: CGPoint, size: CGFloat,
                          color: Int, opacity: CGFloat, in context: GraphicsContext) {
        if symbol == "heart.fill" || symbol == "sparkle" {
            let isHeart = symbol == "heart.fill"
            let scale = size / (isHeart ? 68 : 48)
            var mark = context
            mark.translateBy(x: point.x, y: point.y)
            mark.scaleBy(x: scale, y: scale)
            mark.fill(isHeart ? heartShape : sparkleShape, with: .color(Color(hex: color).opacity(opacity)))
            return
        }
        let glyph = Text(Image(systemName: symbol))
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(Color(hex: color).opacity(opacity))
        context.draw(glyph, at: point)
    }

    private var sparkleShape: Path {
        Path { path in
            path.move(to: CGPoint(x: -22, y: -2))
            path.addCurve(to: CGPoint(x: -2, y: -22),
                          control1: CGPoint(x: -11, y: -2), control2: CGPoint(x: -2, y: -11))
            path.addCurve(to: CGPoint(x: 2, y: -22),
                          control1: CGPoint(x: -2, y: -27), control2: CGPoint(x: 2, y: -27))
            path.addCurve(to: CGPoint(x: 22, y: -2),
                          control1: CGPoint(x: 2, y: -11), control2: CGPoint(x: 11, y: -2))
            path.addCurve(to: CGPoint(x: 22, y: 2),
                          control1: CGPoint(x: 27, y: -2), control2: CGPoint(x: 27, y: 2))
            path.addCurve(to: CGPoint(x: 2, y: 22),
                          control1: CGPoint(x: 11, y: 2), control2: CGPoint(x: 2, y: 11))
            path.addCurve(to: CGPoint(x: -2, y: 22),
                          control1: CGPoint(x: 2, y: 27), control2: CGPoint(x: -2, y: 27))
            path.addCurve(to: CGPoint(x: -22, y: 2),
                          control1: CGPoint(x: -2, y: 11), control2: CGPoint(x: -11, y: 2))
            path.addCurve(to: CGPoint(x: -22, y: -2),
                          control1: CGPoint(x: -27, y: 2), control2: CGPoint(x: -27, y: -2))
            path.closeSubpath()
        }
    }

    private func drawApple(in context: GraphicsContext, at point: CGPoint, bite: CGFloat, opacity: CGFloat) {
        var apple = context
        apple.translateBy(x: point.x, y: point.y)
        apple.scaleBy(x: 1 - 0.24 * bite, y: 1 - 0.24 * bite)
        apple.opacity = opacity * (1 - 0.66 * bite)

        let fruit = Path { path in
            path.move(to: CGPoint(x: 0, y: -11))
            path.addCurve(to: CGPoint(x: 18, y: 2), control1: CGPoint(x: 6, y: -11), control2: CGPoint(x: 21, y: -16))
            path.addCurve(to: CGPoint(x: 0, y: 15), control1: CGPoint(x: 16, y: 13), control2: CGPoint(x: 8, y: 15))
            path.addCurve(to: CGPoint(x: -18, y: 2), control1: CGPoint(x: -8, y: 15), control2: CGPoint(x: -16, y: 13))
            let notch = smoothProgress((bite - 0.18) / 0.25)
            path.addCurve(to: CGPoint(x: 0, y: -11),
                          control1: CGPoint(x: -21 + 11 * notch, y: -16 + 10 * notch),
                          control2: CGPoint(x: -6, y: -11))
            path.closeSubpath()
        }
        apple.fill(fruit, with: .color(Color(hex: 0xFF6676)))
        var leaf = apple
        leaf.translateBy(x: 5, y: -18)
        leaf.rotate(by: .degrees(40))
        leaf.fill(Path(ellipseIn: CGRect(x: -3.5, y: -8, width: 7, height: 16)),
                  with: .color(Color(hex: 0x7FF0A9)))
    }

    private func drawMaraca(in context: GraphicsContext, color: Color, opacity: CGFloat) {
        let head = Path(ellipseIn: CGRect(x: -14, y: -36, width: 28, height: 34))
        let handle = Path(roundedRect: CGRect(x: -4, y: -9, width: 8, height: 34), cornerRadius: 4)
        context.fill(handle, with: .color(Color(hex: 0xFFF0D5).opacity(opacity)))
        context.fill(head, with: .color(color.opacity(opacity)))
        var stripe = context
        stripe.clip(to: head)
        stripe.fill(Path(CGRect(x: -15, y: -22, width: 30, height: 6)),
                    with: .color(.white.opacity(opacity * 0.64)))
    }

    private func drawNotes(in context: GraphicsContext) {
        for side in [-1.0, 1.0] {
            let drift = motionEnabled ? sin(elapsed * 8 + side) * 10 : 0
            let note = Text(side < 0 ? "♪" : "♫")
                .font(.system(size: side < 0 ? 28 : 35, weight: .semibold))
                .foregroundStyle(Color(hex: side < 0 ? 0x81F9DB : 0x9CB6FF).opacity(pose.notes))
            context.draw(note, at: CGPoint(x: side * 150, y: -36 + drift))
        }
    }

    private func drawCelebration(in context: GraphicsContext) {
        let colors = [0x31B8F2, 0xF84994, 0xFFAD4E, 0x4C75FF, 0x63E3C9, 0xFFF2D8]
        let recoil = motionEnabled ? smoothProgress(1 - abs(elapsed - 0.27) / 0.11) : 0
        let cone = Path { path in
            path.move(to: CGPoint(x: -22, y: -20))
            path.addCurve(to: CGPoint(x: 11, y: -8), control1: CGPoint(x: -19, y: -24), control2: CGPoint(x: 1, y: -17))
            path.addCurve(to: CGPoint(x: 11, y: -1), control1: CGPoint(x: 14, y: -5), control2: CGPoint(x: 14, y: -4))
            path.addCurve(to: CGPoint(x: -12, y: 20), control1: CGPoint(x: 4, y: 8), control2: CGPoint(x: -7, y: 17))
            path.addCurve(to: CGPoint(x: -18, y: 17), control1: CGPoint(x: -15, y: 22), control2: CGPoint(x: -17, y: 21))
            path.addCurve(to: CGPoint(x: -22, y: -20), control1: CGPoint(x: -24, y: 3), control2: CGPoint(x: -25, y: -16))
            path.closeSubpath()
        }

        for side in [-1.0, 1.0] {
            var popper = context
            popper.translateBy(x: side * 61, y: 38 + (1 - pose.confetti) * 15 + recoil * 6)
            popper.scaleBy(x: -side, y: 1)
            popper.rotate(by: .degrees(-8 + 12 * recoil))
            popper.opacity = pose.confetti

            popper.fill(cone, with: .color(Color(hex: 0xFFF2F8)))
            var stripes = popper
            stripes.clip(to: cone)
            for y in [-11.0, 3.0, 17.0] {
                let stripe = Path { path in
                    path.move(to: CGPoint(x: -25, y: y + 6))
                    path.addQuadCurve(to: CGPoint(x: 15, y: y - 14), control: CGPoint(x: -3, y: y + 1))
                }
                stripes.stroke(stripe, with: .color(Color(hex: 0xE96D9F)), lineWidth: 2.5)
            }

            for index in 0..<14 {
                let stagger = Double((index + (side > 0 ? 2 : 0)) % 5) * 0.013
                let age = motionEnabled ? elapsed - 0.24 - stagger : 0.26 + stagger
                guard age > 0 else { continue }
                let travel = 1 - pow(1 - min(1, age / 0.44), 3)
                let angle = -3.25 + Double(index) * 0.164 + side * 0.09
                let radius = (37 + Double((index * 3) % 8) * 12) * travel
                let x = side * (58 - cos(angle) * radius)
                let y = 20 + sin(angle) * radius + 87 * age * age
                var ribbon = context
                ribbon.translateBy(x: x, y: y)
                ribbon.rotate(by: .radians(angle + side * age * (2 + Double(index % 4))))
                ribbon.opacity = pose.confetti * min(1, age / 0.055) * max(0, 1 - max(0, age - 0.40) / 0.45)
                let curve = Path { path in
                    path.move(to: .zero)
                    path.addCurve(to: CGPoint(x: 17, y: -2),
                                  control1: CGPoint(x: 6, y: 11), control2: CGPoint(x: 13, y: -8))
                }
                let color = Color(hex: colors[(index + (side > 0 ? 3 : 0)) % colors.count])
                if index.isMultiple(of: 2) {
                    ribbon.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: 5, height: 6),
                                     cornerRadius: 2.5), with: .color(color))
                } else {
                    ribbon.stroke(curve, with: .color(color),
                                  style: StrokeStyle(lineWidth: index.isMultiple(of: 3) ? 5 : 3.5,
                                                     lineCap: .round))
                }
            }
        }
    }

    private func drawGlasses(in context: GraphicsContext) {
        var glasses = context
        let drop = smoothProgress(elapsed / 0.24)
        let rebound = smoothProgress(1 - abs(elapsed - 0.25) / 0.045)
        let push = motionEnabled ? smoothProgress((elapsed - 0.47) / 0.18) : 1
        let settle = motionEnabled ? smoothProgress((elapsed - 0.65) / 0.15) : 1
        let tilt = motionEnabled ? -3 * smoothProgress((elapsed - 0.29) / 0.16) * (1 - push) + 2 * push * (1 - settle) : 0
        let offset = motionEnabled ? -66 * (1 - drop) + 4 * rebound + 5 * (1 - push) - 5 * push * (1 - settle) : 0
        glasses.translateBy(x: 0, y: offset)
        glasses.rotate(by: .degrees(tilt))
        glasses.opacity = pose.glasses

        let white = Color(hex: 0xF9F9FF)
        let bridge = Path { path in
            path.move(to: CGPoint(x: -28, y: -14))
            path.addLine(to: CGPoint(x: 28, y: -14))
        }
        glasses.stroke(bridge, with: .color(white), style: StrokeStyle(lineWidth: 11, lineCap: .round))

        let frame = UnevenRoundedRectangle(topLeadingRadius: 13, bottomLeadingRadius: 23,
                                           bottomTrailingRadius: 23, topTrailingRadius: 13, style: .continuous)
            .path(in: CGRect(x: -45, y: -28, width: 90, height: 62))
        let shading = Gradient(colors: [Color(hex: 0x0D0C16), Color(hex: 0x423D4F)])
        for x in [-65.0, 65.0] {
            var lens = glasses
            lens.translateBy(x: x, y: 0)
            lens.fill(frame, with: .linearGradient(shading, startPoint: CGPoint(x: 0, y: -25),
                                                  endPoint: CGPoint(x: 0, y: 38)))
            lens.stroke(frame, with: .color(white), style: StrokeStyle(lineWidth: 10, lineJoin: .round))
        }

        let corner = CGPoint(x: -110, y: -24).applying(CGAffineTransform(rotationAngle: tilt * .pi / 180))
        drawGlassesHand(in: context, at: CGPoint(x: corner.x, y: corner.y + offset), color: white)
    }

    private func drawGlassesHand(in context: GraphicsContext, at corner: CGPoint, color: Color) {
        let approach = motionEnabled ? smoothProgress((elapsed - 0.18) / 0.29) : 1
        let release = motionEnabled ? smoothProgress((elapsed - 0.71) / 0.34) : 0
        let visibility = motionEnabled ? smoothProgress((elapsed - 0.18) / 0.10)
            * (1 - smoothProgress((elapsed - 0.90) / 0.15)) : 1
        guard visibility > 0.01 else { return }

        let reach = 1 - approach + release
        var hand = context
        hand.translateBy(x: corner.x - 22 - 35 * reach, y: corner.y + 9 + 64 * reach)
        hand.rotate(by: .degrees(-12 * reach))
        hand.opacity = pose.glasses * visibility
        let fingerGap = 8 * reach
        let glove = Path { path in
            path.move(to: CGPoint(x: -17, y: 17))
            path.addQuadCurve(to: CGPoint(x: -16, y: 1), control: CGPoint(x: -23, y: 10))
            path.addQuadCurve(to: CGPoint(x: -4, y: -8), control: CGPoint(x: -12, y: -5))
            path.addQuadCurve(to: CGPoint(x: 15, y: -25 - fingerGap), control: CGPoint(x: 3, y: -20))
            path.addQuadCurve(to: CGPoint(x: 25, y: -17 - fingerGap), control: CGPoint(x: 24, y: -28 - fingerGap))
            path.addQuadCurve(to: CGPoint(x: 10, y: -6), control: CGPoint(x: 23, y: -12 - fingerGap))
            path.addQuadCurve(to: CGPoint(x: 12, y: 2), control: CGPoint(x: 6, y: 0))
            path.addQuadCurve(to: CGPoint(x: 25, y: 1 + fingerGap), control: CGPoint(x: 22, y: -3 + fingerGap))
            path.addQuadCurve(to: CGPoint(x: 19, y: 14), control: CGPoint(x: 30, y: 8 + fingerGap))
            path.addQuadCurve(to: CGPoint(x: 6, y: 24), control: CGPoint(x: 14, y: 25))
            path.addQuadCurve(to: CGPoint(x: -17, y: 17), control: CGPoint(x: -7, y: 28))
            path.closeSubpath()
        }
        hand.fill(glove, with: .color(color))
        hand.stroke(glove, with: .color(Color(hex: 0x969CB9).opacity(0.75)),
                    style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
    }

    private func drawGlassesStreaks(in context: GraphicsContext) {
        let streaks: [(angle: Double, delay: Double, distance: CGFloat)] = [
            (-2.98, 0.04, 183), (-2.69, 0.11, 193), (-2.29, 0.18, 136), (-1.88, 0.07, 98),
            (-1.16, 0.16, 106), (-0.76, 0.09, 155), (-0.39, 0.13, 178), (-0.14, 0.02, 206),
            (0.08, 0.12, 195), (0.35, 0.05, 187), (0.68, 0.17, 161), (1.01, 0.10, 125),
            (2.08, 0.15, 112), (2.52, 0.09, 161), (2.84, 0.16, 187), (3.07, 0.12, 197)
        ]
        for (index, streak) in streaks.enumerated() {
            let age = (elapsed - 0.51 - streak.delay) / 0.59
            guard (0..<1).contains(age) else { continue }
            let fade = smoothProgress(age / 0.20) * (1 - smoothProgress((age - 0.53) / 0.47))
            let advance = 0.62 + 0.52 * age
            let length = 11 + 37 * age
            let direction = CGPoint(x: cos(streak.angle), y: sin(streak.angle))
            let distance = streak.distance * advance
            let start = CGPoint(x: direction.x * (distance - length), y: direction.y * (distance - length) * 0.74)
            let end = CGPoint(x: direction.x * distance, y: direction.y * distance * 0.74)
            let trail = Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            let blue = Color(hex: index.isMultiple(of: 3) ? 0x8197FA : 0x549BFF)
            let strength = Double(pose.glasses) * fade
            var glow = context
            glow.addFilter(.blur(radius: 3.6))
            glow.stroke(trail, with: .color(blue.opacity(strength * 0.64)), style: StrokeStyle(lineWidth: 5.2, lineCap: .round))
            let beam = Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: blue.opacity(strength * 0.60), location: 0.56),
                .init(color: Color(hex: 0x93C8FF).opacity(strength), location: 1)
            ])
            context.stroke(trail, with: .linearGradient(beam, startPoint: start, endPoint: end),
                           style: StrokeStyle(lineWidth: 2.1 + age * 1.5, lineCap: .round))
        }
    }

    private func drawMouth(in context: GraphicsContext) {
        let opening = min(1, max(0, pose.mouthOpen))
        let roundness = pose.mouthRound
        let width = (17 + 6 * max(0, pose.mouthCurve) + 3 * opening) * (1 - roundness * 0.45)
        let y: CGFloat = 64 - opening * 3
        let curve = pose.mouthCurve * 9.75
        let centerY = y + curve + opening * (6 - 5 * roundness) - pose.smirk
        let bend = curve * (1 - 0.8 * smoothProgress(opening / 0.7))
        let tilt = pose.smirk * -4
        let openingHeight = opening * (11 + 5 * roundness)
        let lip = Color(hex: 0xFFF6F1)
        var mouth = context
        mouth.opacity = pose.mouth * min(1, pose.brightness)

        let contour = mouthContour(width: width + 1.6, centerY: centerY, bend: bend,
                                   tilt: tilt, halfHeight: openingHeight + 1.6)

        var glow = mouth
        glow.addFilter(.blur(radius: 4))
        glow.fill(contour, with: .color(lip.opacity(0.38)))
        mouth.drawLayer { layer in
            layer.fill(contour, with: .color(lip))
            guard opening > 0 else { return }

            let cavity = mouthContour(width: width - 1.6, centerY: centerY, bend: bend,
                                      tilt: tilt, halfHeight: openingHeight * smoothProgress(opening / 0.16))
            var interior = layer
            interior.clip(to: contour)
            interior.fill(cavity, with: .color(Color(hex: 0x3B2531).opacity(smoothProgress(opening / 0.20))))
            guard pose.mouthTongue > 0 else { return }

            interior.clip(to: cavity)
            let tongueY = centerY + openingHeight * 0.36
            let tongue = Path(ellipseIn: CGRect(x: -width * 0.57, y: tongueY,
                                                width: width * 1.14, height: opening * 19))
            interior.fill(tongue, with: .color(Color(hex: 0xFF93B0).opacity(pose.mouthTongue * opening)))
        }
    }

    private func mouthContour(width: CGFloat, centerY: CGFloat, bend: CGFloat,
                              tilt: CGFloat, halfHeight: CGFloat) -> Path {
        // Keep a single contour from the closed smile to the open mouth.
        let flatten = 0.48 * (1 - smoothProgress(halfHeight / 11))
        func point(at angle: CGFloat) -> (position: CGPoint, tangent: CGVector) {
            let horizontal = sin(angle)
            let vertical = cos(angle)
            let x = horizontal * (1 + flatten * vertical * vertical)
            let dx = vertical * (1 + flatten * (1 - 3 * horizontal * horizontal))
            let verticalRate = tilt - 2 * bend * x
            let slope = verticalRate / width
            let normalScale = 1 / hypot(1, slope)
            let normal = CGVector(dx: -slope * normalScale, dy: normalScale)
            let normalRate = (2 * bend * dx / width) * normalScale * normalScale * normalScale
            let offset = halfHeight * vertical
            let offsetRate = -halfHeight * horizontal
            return (
                CGPoint(x: width * x + offset * normal.dx,
                        y: centerY + x * (tilt - bend * x) + offset * normal.dy),
                CGVector(dx: width * dx + offsetRate * normal.dx + offset * normalRate,
                         dy: dx * verticalRate + offsetRate * normal.dy + offset * slope * normalRate)
            )
        }

        let sections = 12
        let step = 2 * CGFloat.pi / CGFloat(sections)
        let handle = step / 3
        return Path { path in
            let start = point(at: 0)
            var previous = start
            path.move(to: start.position)
            for index in 1...sections {
                let next = index == sections ? start : point(at: CGFloat(index) * step)
                path.addCurve(to: next.position,
                              control1: CGPoint(x: previous.position.x + previous.tangent.dx * handle,
                                                y: previous.position.y + previous.tangent.dy * handle),
                              control2: CGPoint(x: next.position.x - next.tangent.dx * handle,
                                                y: next.position.y - next.tangent.dy * handle))
                previous = next
            }
            path.closeSubpath()
        }
    }

    private func drawTear(in context: GraphicsContext, x: CGFloat, delay: Double) {
        let phase = PetActionGeometry.tearPhase(at: elapsed, delay: delay, motionEnabled: motionEnabled)
        let fade = min(phase * 7, (1 - phase) * 5, 1) * pose.tears
        let y = 15 + 65 * phase
        let tear = Path { path in
            path.move(to: CGPoint(x: x, y: y - 9))
            path.addCurve(to: CGPoint(x: x + 6, y: y + 4),
                          control1: CGPoint(x: x + 2, y: y - 9), control2: CGPoint(x: x + 6, y: y))
            path.addCurve(to: CGPoint(x: x - 6, y: y + 4),
                          control1: CGPoint(x: x + 6, y: y + 12), control2: CGPoint(x: x - 6, y: y + 12))
            path.addCurve(to: CGPoint(x: x, y: y - 9),
                          control1: CGPoint(x: x - 6, y: y), control2: CGPoint(x: x - 2, y: y - 9))
            path.closeSubpath()
        }
        fillGlowing(tear, color: Color(hex: 0x60C5FF).opacity(fade), in: context)
    }

    private func fillGlowing(_ path: Path, color: Color, in context: GraphicsContext) {
        var glow = context
        glow.addFilter(.blur(radius: 5))
        glow.fill(path, with: .color(color.opacity(0.46)))
        context.fill(path, with: .color(color))
    }
}

private enum PetActionGeometry {
    static let angerMark = CGPoint(x: 118, y: -49)

    static func wave(at time: TimeInterval) -> Double {
        sin(time * 20)
    }

    static func tearPhase(at time: TimeInterval, delay: Double, motionEnabled: Bool) -> Double {
        motionEnabled ? (time * 0.9 + delay).truncatingRemainder(dividingBy: 1) : 0.36
    }

    static func greetingPalm(reach: CGFloat) -> CGPoint {
        CGPoint(x: 150 + 16 * (1 - reach), y: 66 - 46 * reach)
    }

    static func thoughtPulse(at time: TimeInterval, index: Int, motionEnabled: Bool) -> Double {
        guard motionEnabled else { return 0.40 }
        let phase = (time * 4 - Double(index) + 3).truncatingRemainder(dividingBy: 3)
        return smooth(1 - abs(phase - 0.64) / 0.64)
    }

    static func handHeart(reach: CGFloat, lift: Double) -> CGPoint {
        CGPoint(x: 0, y: 58 + (1 - reach) * 46 - lift * 49)
    }

    static func heartLift(at time: TimeInterval, motionEnabled: Bool) -> Double {
        guard motionEnabled else { return 0.42 }
        let t = min(1, max(0, (time - 0.78) / 0.64))
        return t * t * (3 - 2 * t)
    }

    static func kissProgress(at time: TimeInterval) -> Double {
        min(1, max(0, (time - 0.39) / 1.1))
    }

    static func kissPosition(progress: Double) -> CGPoint {
        CGPoint(x: 23 + 120 * progress, y: 43 - 108 * progress)
    }

    static func kissVisibility(at progress: Double, motionEnabled: Bool) -> Double {
        motionEnabled ? particleVisibility(at: progress, fadeIn: 0.12, fadeOut: 0.35) : 0.78
    }

    static func bubbleProgress(at time: TimeInterval) -> Double {
        min(1, max(0, (time - 0.34) / 1.35))
    }

    static func bubblePosition(progress: Double) -> CGPoint {
        // Bubbles drift around the outside of the eye before rising.
        CGPoint(x: 31 + 127 * (1 - pow(1 - progress, 3)),
                y: 43 + 26 * sin(progress * .pi) - 98 * progress * progress * progress)
    }

    static func bubbleVisibility(at progress: Double) -> Double {
        particleVisibility(at: progress, fadeIn: 0.15, fadeOut: 0.20)
    }

    static func particleVisibility(at progress: Double, fadeIn: Double, fadeOut: Double) -> Double {
        smooth(progress / fadeIn) * smooth((1 - progress) / fadeOut)
    }

    private static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}

struct PetScreenGlow: View {
    let expression: PetExpression
    let elapsed: TimeInterval
    let motionEnabled: Bool
    var variant: PetExpressionVariant = .original
    var tintOverride: Color? = nil
    var tintStrength: Double = 1
    var isBaseline = false
    var playbackDuration: TimeInterval? = nil
    var faceOffset: CGSize = .zero
    var faceScale: CGFloat = 1
    var pose = PetExpression.idle.pose
    private let edgeInset: CGFloat = 2

    private struct EdgeLightSpot {
        let color: Int
        let edge: UnitPoint
        let intensity: Double
        let spread: Double
        let anchor: CGPoint
        let highlight: Int?
    }

    private struct EdgeLightFrame {
        var spots: [EdgeLightSpot]
        var lineWidth: CGFloat = 2.4
        var haloWidth: CGFloat = 22
        var blur: CGFloat = 15
        var ringOpacity: Double = 0
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            if size.width > 4, size.height > 4 {
                if #available(iOS 26.0, *) {
                    outline(ConcentricRectangle(), in: size)
                } else {
                    outline(RoundedRectangle(cornerRadius: fallbackRadius(for: size), style: .continuous), in: size)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func outline(_ shape: some Shape, in size: CGSize) -> some View {
        if let tintOverride {
            let warm = gradient(color: tintOverride, highlight: nil, strength: 0.48 * tintStrength,
                                center: .bottom, radius: max(size.width, size.height) * 0.68, tail: 0.16)
            shape.stroke(warm, lineWidth: 2.4)
                .background {
                    shape.stroke(warm, lineWidth: 22)
                        .blur(radius: 15)
                }
                .padding(edgeInset)
        } else {
            let time = motionEnabled
                ? (isBaseline ? elapsed : expression.effectElapsed(at: elapsed, playbackDuration: playbackDuration))
                : expression.motionDuration * 0.38
            let frame = lighting(at: time)
            let envelope = playbackEnvelope(at: time)
            let gradients = frame.spots.compactMap { spot -> RadialGradient? in
                let strength = min(1, max(0, spot.intensity * envelope))
                guard strength > 0.004 else { return nil }
                return gradient(color: Color(hex: spot.color), highlight: spot.highlight.map(Color.init(hex:)),
                                strength: strength, center: edgeOrigin(in: size, near: spot.anchor, toward: spot.edge),
                                radius: min(size.width, size.height) * spot.spread)
            }

            let ring = Color(hex: 0x92FFB6).opacity(frame.ringOpacity * envelope)
            strokes(shape, gradients: gradients, ring: ring, width: frame.lineWidth)
                .background {
                    strokes(shape, gradients: gradients, ring: ring, width: frame.haloWidth)
                        .compositingGroup()
                        .blur(radius: frame.blur)
                }
                .padding(edgeInset)
        }
    }

    private func strokes(_ shape: some Shape, gradients: [RadialGradient], ring: Color, width: CGFloat) -> some View {
        ZStack {
            shape.stroke(ring, lineWidth: width)
            ForEach(gradients.indices, id: \.self) { index in
                shape.stroke(gradients[index], lineWidth: width)
            }
        }
    }

    private func gradient(color: Color, highlight: Color?, strength: Double,
                          center: UnitPoint, radius: CGFloat, tail: Double = 0) -> RadialGradient {
        RadialGradient(stops: [
            .init(color: (highlight ?? color).opacity(strength), location: 0),
            .init(color: color.opacity(strength * 0.68), location: 0.34),
            .init(color: color.opacity(strength * tail), location: 1)
        ], center: center, startRadius: 0, endRadius: radius)
    }

    private func playbackEnvelope(at time: Double) -> Double {
        guard motionEnabled, expression != .idle else { return 1 }
        let release = playbackDuration.map { smooth(($0 - elapsed) / 0.42) } ?? 1
        if expression == .charging {
            return release
        }
        // Fade at each pass boundary so the next expression and glow can enter together.
        let attack = smooth(time / 0.10)
        let loopRelease = smooth((expression.motionDuration - time) / 0.20)
        return attack * loopRelease * release
    }

    private func fallbackRadius(for size: CGSize) -> CGFloat {
        let shortSide = min(size.width, size.height)
        let radius: CGFloat
        // Match common iPhone display sizes when system concentric corners are unavailable.
        switch shortSide.rounded() {
        case 402, 420, 440: radius = 62
        case 393, 430: radius = 55
        case 428: radius = 53
        case 390: radius = 47
        case 360: radius = 44
        case 375: radius = max(size.width, size.height) < 700 ? 0 : 39
        case 414: radius = 40
        default: radius = min(48, shortSide * 0.12)
        }
        return max(0, radius - edgeInset)
    }

    private func spot(_ color: Int, _ edge: UnitPoint, _ intensity: Double, spread: Double = 0.48,
                      anchor: CGPoint = .zero, highlight: Int? = nil) -> EdgeLightSpot {
        EdgeLightSpot(color: color, edge: edge, intensity: intensity, spread: spread,
                      anchor: anchor, highlight: highlight)
    }

    private func accent(_ expected: PetAccent) -> Double {
        pose.accent == expected ? Double(pose.accentOpacity) : 0
    }

    private func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    private func ramp(_ time: Double, _ start: Double, _ end: Double) -> Double {
        smooth((time - start) / (end - start))
    }

    private func pulse(_ time: Double, at peak: Double, attack: Double, decay: Double) -> Double {
        ramp(time, peak - attack, peak) * (1 - ramp(time, peak, peak + decay))
    }

    private func edgeOrigin(in size: CGSize, near anchor: CGPoint, toward edge: UnitPoint) -> UnitPoint {
        let angle = pose.turn * 5 * .pi / 180
        let x = anchor.x * (1 - abs(pose.turn) * 0.065)
        let actionX = x * cos(angle) - anchor.y * sin(angle)
        let actionY = x * sin(angle) + anchor.y * cos(angle)
        let dx = faceOffset.width + (pose.lookX + actionX) * faceScale
        let dy = faceOffset.height + (pose.lookY + pose.bounce + actionY) * faceScale
        let rayX = edge.x * 2 - 1 + 3.3 * dx / size.width
        let rayY = edge.y * 2 - 1 + 3.3 * dy / size.height
        let distance = max(0.50, abs(rayX), abs(rayY))
        return UnitPoint(x: 0.5 + rayX / distance * 0.5, y: 0.5 + rayY / distance * 0.5)
    }

    private func lighting(at time: Double) -> EdgeLightFrame {
        var frame = choreography(at: time)
        guard expression != .happy, expression.hasVariants, variant != .original else { return frame }

        // Keep each action's colors and projected prop positions. The edge light responds to the face's movement.
        let movement = motionEnabled ? smooth(Double(max(abs(pose.bounce) / 13, abs(pose.lookX) / 26,
                                                        abs(pose.lookY) / 18))) : 0.35
        switch variant {
        case .original:
            break
        case .second:
            frame.spots = frame.spots.map { light in
                spot(light.color, light.edge, light.intensity * (0.96 + 0.35 * movement),
                     spread: light.spread * (0.55 + 0.15 * movement), anchor: light.anchor,
                     highlight: light.highlight)
            }
            frame.lineWidth *= 1.22
            frame.haloWidth *= 0.77
            frame.blur *= 0.73
        case .third:
            frame.spots = frame.spots.map { light in
                spot(light.color, light.edge, light.intensity * (0.69 + 0.22 * movement),
                     spread: light.spread * (1.35 + 0.44 * movement), anchor: light.anchor)
            }
            frame.lineWidth *= 0.75
            frame.haloWidth *= 1.46
            frame.blur *= 1.40
        }
        return frame
    }

    private func happyLighting(at time: Double) -> EdgeLightFrame {
        let smile = Double(pose.cheeks)
        switch variant {
        case .original:
            let spread = motionEnabled ? ramp(time, 0.12, 0.50) : 0.85
            return EdgeLightFrame(spots: [
                spot(0xFF957E, UnitPoint(x: 0.48 - 0.22 * spread, y: 1), smile * 0.76,
                     spread: 0.34 + 0.13 * spread, anchor: CGPoint(x: -75 * spread, y: 34)),
                spot(0xFF7698, UnitPoint(x: 0.52 + 0.22 * spread, y: 1), smile * 0.76,
                     spread: 0.34 + 0.13 * spread, anchor: CGPoint(x: 75 * spread, y: 34))
            ])
        case .second:
            let first = pulse(time, at: 0.40, attack: 0.19, decay: 0.26)
            let second = pulse(time, at: 0.86, attack: 0.19, decay: 0.40)
            let beat = motionEnabled ? max(first, second * 0.83) : 0.65
            return EdgeLightFrame(spots: [
                spot(0xFFB75D, .bottom, smile * (0.34 + 0.58 * beat), spread: 0.42 + 0.26 * beat,
                     anchor: CGPoint(x: 0, y: 37), highlight: 0xFFF0BE)
            ], lineWidth: 2.8, haloWidth: 25, blur: 16)
        case .third:
            let lift = motionEnabled ? pulse(time, at: 0.45, attack: 0.27, decay: 0.37) : 0.60
            let returnGlow = motionEnabled ? pulse(time, at: 0.95, attack: 0.26, decay: 0.39) : 0.53
            return EdgeLightFrame(spots: [
                spot(0xFFAD97, UnitPoint(x: 1, y: 0.88 - 0.45 * lift), smile * (0.15 + 0.73 * lift),
                     spread: 0.31 + 0.16 * lift, anchor: CGPoint(x: 69, y: 31), highlight: 0xFFE4C7),
                spot(0xFF86BB, UnitPoint(x: 0.43 - 0.33 * returnGlow, y: 1), smile * (0.15 + 0.64 * returnGlow),
                     spread: 0.47 + 0.18 * returnGlow, anchor: CGPoint(x: -35, y: 37))
            ], lineWidth: 2.0, haloWidth: 29, blur: 20)
        }
    }

    private func choreography(at time: Double) -> EdgeLightFrame {
        switch expression {
        case .idle:
            let breath = motionEnabled ? 0.5 + 0.5 * sin(time * 1.35) : 0.5
            let open = min(1, max(pose.left.height, pose.right.height))
            return EdgeLightFrame(spots: [
                spot(0x8EC2FF, .bottom, 0.045 + 0.04 * breath * open, spread: 1.25)
            ], lineWidth: 1.5, haloWidth: 14, blur: 13)

        case .happy:
            return happyLighting(at: time)

        case .laughing:
            let beats = [0.37, 0.78, 1.20]
            let bounce = motionEnabled
                ? beats.enumerated().reduce(0.0) { value, beat in
                    max(value, (1 - 0.16 * Double(beat.offset)) * pulse(time, at: beat.element, attack: 0.13, decay: 0.28))
                }
                : 0.65
            let power = (0.20 + 0.80 * bounce) * accent(.laugh)
            return EdgeLightFrame(spots: [
                spot(0xFFBB50, .leading, power, spread: 0.42 + 0.27 * bounce, anchor: CGPoint(x: -131, y: -31)),
                spot(0xFFD575, .trailing, power, spread: 0.42 + 0.27 * bounce, anchor: CGPoint(x: 131, y: -31))
            ], lineWidth: 2.5, haloWidth: 26)

        case .angry:
            let impact = motionEnabled ? pulse(time, at: 0.21, attack: 0.11, decay: 0.48) : 0.46
            let anger = Double(pose.anger)
            let edge = UnitPoint(x: 0.78, y: 0)
            return EdgeLightFrame(spots: [
                spot(0xFF382E, edge, anger * (0.31 + 0.69 * impact),
                     spread: 0.43 + 0.43 * impact, anchor: PetActionGeometry.angerMark),
                spot(0xFF852D, edge, anger * impact * 0.60,
                     spread: 0.17 + 0.12 * impact, anchor: PetActionGeometry.angerMark, highlight: 0xFFDB8A)
            ], lineWidth: 2.2 + 1.6 * impact, haloWidth: 21 + 13 * impact)

        case .proud:
            let lift = ramp(time, 0.10, 0.80)
            let glint = motionEnabled ? pulse(time, at: 1.04, attack: 0.18, decay: 0.43) : 0.48
            let smirk = min(1, Double(pose.smirk))
            let edge = UnitPoint(x: 1, y: 0.63 - 0.51 * lift)
            return EdgeLightFrame(spots: [
                spot(0xEFAF53, edge, smirk * (0.32 + 0.32 * lift), spread: 0.40, anchor: CGPoint(x: 76, y: pose.right.lift)),
                spot(0xFFE5A4, edge, glint * smirk * 0.86, spread: 0.17, anchor: CGPoint(x: 76, y: -18))
            ], haloWidth: 17, blur: 11)

        case .sad:
            let sink = ramp(time, 0.20, 1.15)
            let drain = ramp(time, 1.60, 3.16)
            let power = ramp(time, 0.05, 0.55) * (1 - 0.91 * drain)
            return EdgeLightFrame(spots: [
                spot(0x7587D1, UnitPoint(x: 0.33 + 0.17 * sink, y: 1), 0.59 * power,
                     spread: 0.80 - 0.47 * drain, anchor: CGPoint(x: 0, y: 35))
            ], lineWidth: 1.7, haloWidth: 21, blur: 20)

        case .crying:
            let tears = Double(pose.tears)
            let left = PetActionGeometry.tearPhase(at: time, delay: 0, motionEnabled: motionEnabled)
            let right = PetActionGeometry.tearPhase(at: time, delay: 0.48, motionEnabled: motionEnabled)
            let leftFall = pulse(left, at: 0.66, attack: 0.62, decay: 0.34)
            let rightFall = pulse(right, at: 0.66, attack: 0.62, decay: 0.34)
            let ripple = max(pulse(left, at: 0.88, attack: 0.18, decay: 0.12),
                             pulse(right, at: 0.88, attack: 0.18, decay: 0.12))
            return EdgeLightFrame(spots: [
                spot(0x5DBAFF, UnitPoint(x: 0, y: 0.42 + left * 0.57), tears * leftFall * 0.84,
                     spread: 0.29, anchor: CGPoint(x: -76, y: 15 + 65 * left)),
                spot(0x6CD8FC, UnitPoint(x: 1, y: 0.42 + right * 0.57), tears * rightFall * 0.84,
                     spread: 0.29, anchor: CGPoint(x: 76, y: 15 + 65 * right)),
                spot(0x82C9FF, .bottom, tears * ripple * 0.60, spread: 0.46)
            ], haloWidth: 17, blur: 12)

        case .surprised:
            let snap = motionEnabled ? pulse(time, at: 0.24, attack: 0.12, decay: 0.52) : 0.70
            let echo = pulse(time, at: 0.44, attack: 0.20, decay: 0.62)
            return EdgeLightFrame(spots: [
                spot(0xE3EFFF, .leading, snap * 0.84, spread: 0.36 + 0.20 * snap, anchor: CGPoint(x: -76, y: -7)),
                spot(0xE3EFFF, .trailing, snap * 0.84, spread: 0.36 + 0.20 * snap, anchor: CGPoint(x: 76, y: -7)),
                spot(0xA9CFFF, .top, echo * 0.42, spread: 0.55)
            ], lineWidth: 2.9, haloWidth: 28, blur: 17)

        case .curious:
            let gaze = max(-1, min(1, pose.lookX / 19))
            let focus = ramp(time, 0.13, 0.47) * (1 - ramp(time, 2.23, 3.0))
            return EdgeLightFrame(spots: [
                spot(0xB098FF, UnitPoint(x: 0.5 + 0.37 * gaze, y: 0),
                     focus * (0.43 + 0.37 * abs(gaze)), spread: 0.25 + 0.15 * (1 - abs(gaze)),
                     anchor: CGPoint(x: gaze * 38, y: -32))
            ], lineWidth: 2.0, haloWidth: 15, blur: 11)

        case .shy:
            let tuck = ramp(time, 0.27, 0.85)
            let retreat = ramp(time, 1.45, 2.10)
            return EdgeLightFrame(spots: [
                spot(0xFFA2AF, UnitPoint(x: 0.27 - 0.19 * retreat, y: 1 - 0.16 * retreat),
                     Double(pose.cheeks) * tuck * (0.67 - 0.48 * retreat),
                     spread: 0.25 + 0.14 * tuck - 0.17 * retreat, anchor: CGPoint(x: -105, y: 36))
            ], lineWidth: 1.6, haloWidth: 26, blur: 20)

        case .greeting:
            // The light brushes up and down on the waving hand's side.
            let hand = PetActionGeometry.greetingPalm(reach: pose.greeting)
            let swing = motionEnabled ? PetActionGeometry.wave(at: time) : 0.0
            let reach = Double(pose.greeting)
            let edge = UnitPoint(x: 1, y: 0.53 - swing * 0.25)
            return EdgeLightFrame(spots: [
                spot(0x6FF5DA, edge, reach * (0.58 + 0.32 * (swing + 1) / 2),
                     spread: 0.33, anchor: hand, highlight: 0xD9FFF5),
                spot(0x48CDBE, UnitPoint(x: 1, y: edge.y + 0.14), reach * 0.26, spread: 0.20, anchor: hand)
            ], lineWidth: 2.8, haloWidth: 17)
        case .winking:
            let spark = motionEnabled ? pulse(time, at: 0.44, attack: 0.13, decay: 0.37) : 0.72
            let tail = motionEnabled ? ramp(time, 0.44, 0.75) : 0.35
            return EdgeLightFrame(spots: [
                spot(0xFFDE8F, UnitPoint(x: 0, y: 0.31 - tail * 0.15), spark * accent(.wink),
                     spread: 0.15 + tail * 0.15, anchor: CGPoint(x: -131, y: -35), highlight: 0xFFF9DC)
            ], lineWidth: 3.3, haloWidth: 16, blur: 10)
        case .peeking:
            let lean = min(1, max(-1, pose.lookX / 72))
            let reach = smooth(abs(lean))
            let edge = UnitPoint(x: 0.5 + lean * 0.5, y: 0.78 - reach * 0.21)
            return EdgeLightFrame(spots: [
                spot(0x72F2AF, edge, accent(.peek) * (0.34 + 0.58 * reach),
                     spread: 0.27 + 0.22 * reach, highlight: 0xC5FFDF)
            ], lineWidth: 2.5, haloWidth: 23)
        case .listening:
            let breath = motionEnabled ? (1 - cos(time * 2 * .pi / expression.motionDuration)) / 2 : 0.5
            return EdgeLightFrame(spots: [
                spot(0x83DDD3, .leading, 0.22 + breath * 0.10, spread: 0.52, anchor: CGPoint(x: -76, y: -13)),
                spot(0x83DDD3, .trailing, 0.22 + breath * 0.10, spread: 0.52, anchor: CGPoint(x: 76, y: -13))
            ], lineWidth: 1.8, haloWidth: 18, blur: 14)
        case .thinking:
            // Three stepping dots follow the thought bubbles across the top edge.
            let dots = (0..<3).map { index in
                let step = Double(index)
                let pulse = PetActionGeometry.thoughtPulse(at: time, index: index, motionEnabled: motionEnabled)
                return spot(0xB9A4FF, UnitPoint(x: 0.44 + step * 0.21, y: 0),
                            accent(.thought) * (0.20 + 0.60 * pulse), spread: 0.13,
                            anchor: CGPoint(x: 126 + 18 * step, y: -48 - 7 * step),
                            highlight: 0xE9DFFF)
            }
            return EdgeLightFrame(spots: dots, lineWidth: 2.2, haloWidth: 13, blur: 9)
        case .confused:
            // A crooked pair of highlights trades places when the eyes swap.
            let swap = ramp(time, 0.96, 1.26)
            let query = accent(.question)
            let first = motionEnabled ? 0.83 - swap * 0.57 : 0.58
            let second = motionEnabled ? 0.31 + swap * 0.53 : 0.48
            return EdgeLightFrame(spots: [
                spot(0xE7A6F6, UnitPoint(x: 0.63 + 0.22 * swap, y: 0), first * query,
                     spread: 0.25, anchor: CGPoint(x: 122, y: -52)),
                spot(0xAC8FFF, UnitPoint(x: 1, y: 0.43 - 0.17 * swap), second * query,
                     spread: 0.17, anchor: CGPoint(x: 157, y: -25))
            ], lineWidth: 3.0, haloWidth: 17, blur: 12)
        case .kiss:
            // Short, overlapping tails follow the three hearts, with the first brightest.
            let trail = (0..<3).map { index in
                let step = Double(index)
                let travel = PetActionGeometry.kissProgress(at: time - step * 0.13)
                let launch = PetActionGeometry.kissVisibility(at: travel, motionEnabled: motionEnabled)
                let edge = UnitPoint(x: 0.55 + 0.45 * travel, y: 1 - 0.94 * travel)
                return spot(0xFF609E, edge, accent(.kiss) * launch * (0.88 - 0.17 * step),
                            spread: 0.30 - 0.04 * step, anchor: PetActionGeometry.kissPosition(progress: travel),
                            highlight: 0xFFD1E6)
            }
            return EdgeLightFrame(spots: trail, lineWidth: 3.0, haloWidth: 19, blur: 12)
        case .affectionate:
            // Both eyes feed the same gentle double heartbeat.
            let first = pulse(time, at: 0.37, attack: 0.15, decay: 0.30)
            let second = pulse(time, at: 0.62, attack: 0.10, decay: 0.36)
            let echo = pulse(time, at: 1.22, attack: 0.15, decay: 0.37)
            let beat = motionEnabled ? max(first, second * 0.77, echo * 0.57) : 0.62
            let light = Double(pose.hearts) * (0.33 + beat * 0.60)
            return EdgeLightFrame(spots: [
                spot(0xFF599D, UnitPoint(x: 0.30, y: 1), light, spread: 0.33 + 0.11 * beat,
                     anchor: CGPoint(x: -76, y: 0), highlight: 0xFFB1D3),
                spot(0xFF599D, UnitPoint(x: 0.70, y: 1), light, spread: 0.33 + 0.11 * beat,
                     anchor: CGPoint(x: 76, y: 0), highlight: 0xFFB1D3)
            ], lineWidth: 2.6 + beat, haloWidth: 19 + 10 * beat, blur: 16)
        case .handHeart:
            // The palms' two pools converge, then a single glow opens under the raised heart.
            let hand = accent(.handHeart)
            let lift = PetActionGeometry.heartLift(at: time, motionEnabled: motionEnabled)
            let handLight = hand * (0.78 - 0.63 * lift)
            let palm = 35 + (1 - hand) * 36
            let heart = PetActionGeometry.handHeart(reach: pose.accentOpacity, lift: lift)
            return EdgeLightFrame(spots: [
                spot(0xFB68B8, UnitPoint(x: 0.10 + 0.35 * lift, y: 1), handLight,
                     spread: 0.35, anchor: CGPoint(x: -palm, y: 63)),
                spot(0xFB68B8, UnitPoint(x: 0.90 - 0.35 * lift, y: 1), handLight,
                     spread: 0.35, anchor: CGPoint(x: palm, y: 63)),
                spot(0xFF95C8, .bottom, hand * (0.16 + 0.76 * lift), spread: 0.24 + 0.40 * lift,
                     anchor: heart, highlight: 0xFFE3ED)
            ], lineWidth: 2.2 + 1.3 * lift, haloWidth: 19 + 9 * lift)
        case .thumbsUp:
            let lift = ramp(time, 0.26, 0.52)
            let thumbs = accent(.thumbsUp)
            let snap = motionEnabled ? pulse(time, at: 0.46, attack: 0.13, decay: 0.35) : 0.68
            let edgeY = 0.92 - 0.33 * lift
            let glow = thumbs * (0.48 + 0.52 * snap)
            return EdgeLightFrame(spots: [
                spot(0xFFD075, UnitPoint(x: 0, y: edgeY), glow, spread: 0.33,
                     anchor: CGPoint(x: -134, y: 59), highlight: 0xFFF1CF),
                spot(0xFFD075, UnitPoint(x: 1, y: edgeY), glow, spread: 0.33,
                     anchor: CGPoint(x: 134, y: 59), highlight: 0xFFF1CF)
            ], lineWidth: 3.1, haloWidth: 16, blur: 11)
        case .hungry:
            // The food gets the first gleam. As the eyes lower, the glow settles near the mouth.
            let attention = ramp(time, 0.99, 1.49)
            let hunger = accent(.hungry)
            let anticipation = ramp(time, 0.23, 0.85)
            return EdgeLightFrame(spots: [
                spot(0xFFA354, UnitPoint(x: 1, y: 0.34), hunger * (0.37 + 0.60 * anticipation) * (1 - 0.78 * attention),
                     spread: 0.19 + 0.21 * anticipation, anchor: CGPoint(x: 140, y: -26), highlight: 0xFFDEA2),
                spot(0xF69845, UnitPoint(x: 0.63, y: 1), hunger * attention * 0.54, spread: 0.28,
                     anchor: CGPoint(x: 18, y: 57))
            ], lineWidth: 2.5, haloWidth: 20, blur: 13)
        case .munching:
            // Two small crumbs scatter in opposite directions on the chewing beats.
            let left = pulse(time, at: 0.57, attack: 0.17, decay: 0.37)
            let right = pulse(time, at: 1.03, attack: 0.18, decay: 0.40)
            let crumbs = accent(.crumbs)
            let scatter = ramp(time, 0.53, 1.42)
            let leftEdge = UnitPoint(x: 0.40 - 0.31 * scatter, y: 1)
            let rightEdge = UnitPoint(x: 0.58 + 0.32 * scatter, y: 1)
            return EdgeLightFrame(spots: [
                spot(0xFFBC72, leftEdge, crumbs * (motionEnabled ? 0.20 + 0.72 * left : 0.58), spread: 0.19,
                     anchor: CGPoint(x: -31, y: 53), highlight: 0xFFF1C6),
                spot(0xFF8853, rightEdge, crumbs * (motionEnabled ? 0.20 + 0.74 * right : 0.58), spread: 0.18,
                     anchor: CGPoint(x: 35, y: 53), highlight: 0xFFE0AC)
            ], lineWidth: 2.2, haloWidth: 12, blur: 10)
        case .bubbles:
            // Cool pearls rise one by one, growing translucent as they drift up the side.
            let bubbles = (0..<4).map { index in
                let step = Double(index)
                let travel = PetActionGeometry.bubbleProgress(at: time - step * 0.22)
                let visible = PetActionGeometry.bubbleVisibility(at: travel)
                let edge = UnitPoint(x: 0.80 + 0.20 * smooth(travel * 2), y: 0.97 - 0.83 * travel)
                let color = index.isMultiple(of: 2) ? 0x79DDFF : 0xA99EFF
                return spot(color, edge, accent(.bubbles) * visible * (0.77 - step * 0.10),
                            spread: 0.13 + 0.16 * travel, anchor: PetActionGeometry.bubblePosition(progress: travel),
                            highlight: 0xD8FAFF)
            }
            return EdgeLightFrame(spots: bubbles, lineWidth: 1.9, haloWidth: 21, blur: 16)

        case .celebrate:
            // Follow the two party poppers as the confetti fans out and falls.
            let flight = ramp(time, 0.24, 0.76)
            let burst = motionEnabled ? pulse(time, at: 0.32, attack: 0.08, decay: 0.60) : 0.75
            let confetti = Double(pose.confetti) * burst
            let left = UnitPoint(x: 0.28 * (1 - flight), y: 0.16 + 0.55 * flight)
            let right = UnitPoint(x: 1 - left.x, y: left.y)
            return EdgeLightFrame(spots: [
                spot(0x38C5FF, left, confetti * 0.95, spread: 0.33,
                     anchor: CGPoint(x: -61, y: 20), highlight: 0xC5FAFF),
                spot(0xFF5B96, right, confetti, spread: 0.33,
                     anchor: CGPoint(x: 61, y: 20), highlight: 0xFFD295),
                spot(0xFFD06D, UnitPoint(x: 0.36 - 0.16 * flight, y: 0), confetti * 0.62, spread: 0.22),
                spot(0x9FFFE0, UnitPoint(x: 0.64 + 0.16 * flight, y: 0), confetti * 0.62, spread: 0.22)
            ], lineWidth: 3.2, haloWidth: 27)

        case .delighted:
            // Each star eye catches its own brief glint.
            let stars = Double(pose.stars)
            let left = motionEnabled ? pulse(time, at: 0.23, attack: 0.11, decay: 0.31) : 0.70
            let right = motionEnabled ? pulse(time, at: 0.48, attack: 0.15, decay: 0.46) : 0.55
            return EdgeLightFrame(spots: [
                spot(0xFFC366, UnitPoint(x: 0.31, y: 0), stars * (0.19 + left * 0.79), spread: 0.26,
                     anchor: CGPoint(x: -76, y: -13), highlight: 0xFFF9D2),
                spot(0xFFDB8A, UnitPoint(x: 0.69, y: 0), stars * (0.19 + right * 0.79), spread: 0.23,
                     anchor: CGPoint(x: 76, y: -13), highlight: 0xFFFAE3)
            ], lineWidth: 2.6, haloWidth: 15, blur: 10)

        case .cool:
            let glasses = Double(pose.glasses)
            let burst = motionEnabled ? pulse(time, at: 0.69, attack: 0.16, decay: 0.44) : 0.22
            return EdgeLightFrame(spots: [
                spot(0x466EC5, UnitPoint(x: 0, y: 0.48), glasses * burst * 0.32, spread: 0.35),
                spot(0x567CCF, UnitPoint(x: 1, y: 0.46), glasses * burst * 0.40, spread: 0.38)
            ], lineWidth: 1.8, haloWidth: 12, blur: 9)

        case .sleepy:
            // Small, staggered lights drift up beside the Zs as the eyes close.
            let sleep = Double(pose.sleep)
            let drift = ramp(time, 0.98, 2.72)
            let phase = motionEnabled ? time * 2.5 : 0
            return EdgeLightFrame(spots: [
                spot(0x8585DD, UnitPoint(x: 1, y: 0.50 - 0.28 * drift), sleep * (0.36 + 0.12 * sin(phase)),
                     spread: 0.31, anchor: CGPoint(x: 112, y: -26)),
                spot(0xC0ACF7, UnitPoint(x: 1, y: 0.41 - 0.32 * drift),
                     sleep * ramp(time, 0.84, 1.52) * (0.30 + 0.11 * sin(phase - 0.7)),
                     spread: 0.24, anchor: CGPoint(x: 134, y: -40)),
                spot(0xDFD3FF, UnitPoint(x: 0.89 + 0.11 * drift, y: 0.29 - 0.29 * drift),
                     sleep * ramp(time, 1.16, 1.87) * (0.25 + 0.09 * sin(phase - 1.4)),
                     spread: 0.20, anchor: CGPoint(x: 156, y: -54))
            ], lineWidth: 1.5, haloWidth: 14, blur: 19)

        case .yawning:
            // The lower glow swells with the open mouth, then exhales into the moon corner.
            let opening = Double(pose.mouthOpen) * accent(.yawn)
            let exhale = ramp(time, 1.12, 1.87)
            let breath = motionEnabled ? pulse(time, at: 1.19, attack: 0.57, decay: 1.04) : 0.80
            return EdgeLightFrame(spots: [
                spot(0xA494DA, .bottom, opening * (1 - exhale * 0.84) * 0.82,
                     spread: 0.41 + opening * 0.50, anchor: CGPoint(x: 0, y: 61)),
                spot(0xCEC3FF, UnitPoint(x: 1 - 0.18 * exhale, y: 0.81 * (1 - exhale)),
                     breath * opening * (0.20 + 0.55 * exhale), spread: 0.42,
                     anchor: CGPoint(x: 139, y: -45))
            ], lineWidth: 1.7, haloWidth: 33, blur: 24)

        case .dizzy:
            // The two lights revolve in opposite directions, just like the spiral eyes.
            let spin = motionEnabled ? time * 2.4 : 0.90
            let spirals = Double(pose.spirals)
            return EdgeLightFrame(spots: [
                spot(0xBA8AFF, UnitPoint(x: 0.5 + 0.5 * cos(spin), y: 0.5 + 0.5 * sin(spin)),
                     spirals * 0.76, spread: 0.39, anchor: CGPoint(x: -76, y: 0)),
                spot(0x8FD9FF, UnitPoint(x: 0.5 - 0.5 * cos(spin), y: 0.5 + 0.5 * sin(spin)),
                     spirals * 0.66, spread: 0.33, anchor: CGPoint(x: 76, y: 0))
            ], lineWidth: 2.2, haloWidth: 24)

        case .musical:
            // Two slow side waves float with the notes and alternate on the head-bob beat.
            let notes = Double(pose.notes)
            let phase = motionEnabled ? (time - 0.37) * .pi / 0.48 : 0
            let left = (1 + cos(phase)) / 2
            let right = 1 - left
            let leftDrift = motionEnabled ? sin(time * 8 - 1) : 0
            let rightDrift = motionEnabled ? sin(time * 8 + 1) : 0
            return EdgeLightFrame(spots: [
                spot(0x58D9C6, UnitPoint(x: 0, y: 0.38 + 0.08 * leftDrift), notes * (0.27 + 0.58 * left),
                     spread: 0.54, anchor: CGPoint(x: -150, y: -36 + 10 * leftDrift)),
                spot(0x83AEFF, UnitPoint(x: 1, y: 0.38 + 0.08 * rightDrift), notes * (0.27 + 0.58 * right),
                     spread: 0.54, anchor: CGPoint(x: 150, y: -36 + 10 * rightDrift))
            ], lineWidth: 2, haloWidth: 25, blur: 18)

        case .freezing:
            // Icy fronts start at the top and descend together before they melt away.
            let frost = ramp(time, 0.20, 0.53) * (1 - ramp(time, 1.82, 2.40))
            let drift = ramp(time, 0.35, 1.76)
            let tension = motionEnabled ? 0.94 + 0.06 * sin(time * 14) : 0.94
            let sideY = 0.09 + 0.75 * drift
            return EdgeLightFrame(spots: [
                spot(0xB8EDFF, UnitPoint(x: 0, y: sideY), frost * 0.78 * tension,
                     spread: 0.42 + 0.14 * drift, anchor: CGPoint(x: -135, y: -48), highlight: 0xE7FAFF),
                spot(0xB8EDFF, UnitPoint(x: 1, y: sideY), frost * 0.78 * tension,
                     spread: 0.42 + 0.14 * drift, anchor: CGPoint(x: 135, y: -48), highlight: 0xE7FAFF),
                spot(0x82C8EE, .top, frost * (1 - drift) * 0.46, spread: 0.82)
            ], lineWidth: 3.5, haloWidth: 18, blur: 13)

        case .dancing:
            // Opposite corners take turns on the actual five dance beats.
            let left = max(pulse(time, at: 0.30, attack: 0.15, decay: 0.23),
                           pulse(time, at: 1.12, attack: 0.15, decay: 0.23),
                           pulse(time, at: 1.94, attack: 0.15, decay: 0.32))
            let right = max(pulse(time, at: 0.71, attack: 0.15, decay: 0.23),
                            pulse(time, at: 1.53, attack: 0.15, decay: 0.23))
            let dance = accent(.dance)
            let leftBeat = dance * (0.15 + 0.84 * (motionEnabled ? left : 0.56))
            let rightBeat = dance * (0.15 + 0.84 * (motionEnabled ? right : 0.36))
            return EdgeLightFrame(spots: [
                spot(0xE77BFF, .topLeading, leftBeat, spread: 0.47, anchor: CGPoint(x: -142, y: -25)),
                spot(0x64EED9, .bottomTrailing, leftBeat * 0.58, spread: 0.38),
                spot(0x64EED9, .topTrailing, rightBeat, spread: 0.47, anchor: CGPoint(x: 142, y: -25)),
                spot(0xE77BFF, .bottomLeading, rightBeat * 0.58, spread: 0.38)
            ], lineWidth: 3.2, haloWidth: 24, blur: 13)

        case .maracas:
            // The two lower spots wobble with their own shaker; the light stays on between rattles.
            let reach = accent(.maracas)
            let leftShake = motionEnabled ? sin(time * 26 - 1.4) : 0
            let rightShake = motionEnabled ? sin(time * 26 + 1.4) : 0
            let swing = ramp(time, 0.18, 0.42) * (1 - ramp(time, 2.44, 2.88))
            let leftY = 48 + 10 * leftShake
            let rightY = 48 + 10 * rightShake
            return EdgeLightFrame(spots: [
                spot(0xFF986A, UnitPoint(x: 0.10, y: 0.86 + 0.04 * leftShake),
                     reach * swing * (0.67 + 0.10 * leftShake), spread: 0.29,
                     anchor: CGPoint(x: -131, y: leftY)),
                spot(0x68EDCF, UnitPoint(x: 0.90, y: 0.86 + 0.04 * rightShake),
                     reach * swing * (0.67 + 0.10 * rightShake), spread: 0.29,
                     anchor: CGPoint(x: 131, y: rightY))
            ], lineWidth: 2.9, haloWidth: 16, blur: 9)

        case .charging:
            // After the plug connects, current flows from the cable toward the battery.
            let cable = accent(.charging)
            let connected = ramp(time, 0.67, 0.85)
            let flow = motionEnabled ? (max(0, time - 0.82) / 0.60).truncatingRemainder(dividingBy: 1) : 0.45
            let packet = connected * cable * min(1, flow * 8, (1 - flow) * 6)
            return EdgeLightFrame(spots: [
                spot(0x2CA996, .bottomTrailing, cable * (0.23 + 0.22 * connected), spread: 0.61,
                     anchor: CGPoint(x: 206, y: 103)),
                spot(0x69F7CF, UnitPoint(x: 0.98 - 0.55 * flow, y: 1), packet * 0.88,
                     spread: 0.24, anchor: CGPoint(x: 186 * (1 - flow), y: 54), highlight: 0xDEFFF2)
            ], lineWidth: 2.8, haloWidth: 18, blur: 12)

        case .charged:
            // Fill from the bottom center and hold a complete, soft ring when the battery is full.
            let power = accent(.power)
            let fill = ramp(time, 0.18, 0.58)
            let lock = motionEnabled ? pulse(time, at: 0.36, attack: 0.16, decay: 0.46) : 0.24
            let brightness = power * (0.57 + 0.37 * lock)
            return EdgeLightFrame(spots: [
                spot(0x6AEFA1, .bottom, brightness * (1 - 0.62 * fill), spread: 0.55 + fill * 0.72,
                     anchor: CGPoint(x: 0, y: 64), highlight: 0xC0FFD0),
                spot(0xAAFFD0, .top, power * lock * fill * 0.68, spread: 0.54)
            ], lineWidth: 2.8, haloWidth: 26, blur: 17, ringOpacity: brightness * fill * 0.66)
        }
    }
}

struct PetBatteryGlow: View {
    let level: Double

    var body: some View {
        Canvas { context, size in
            guard size.width > 4, size.height > 4 else { return }
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            let radius = min(48, min(bounds.width, bounds.height) * 0.12)
            let bottom = Path { path in
                path.move(to: CGPoint(x: bounds.minX, y: bounds.maxY - radius))
                path.addQuadCurve(to: CGPoint(x: bounds.minX + radius, y: bounds.maxY),
                                  control: CGPoint(x: bounds.minX, y: bounds.maxY))
                path.addLine(to: CGPoint(x: bounds.maxX - radius, y: bounds.maxY))
                path.addQuadCurve(to: CGPoint(x: bounds.maxX, y: bounds.maxY - radius),
                                  control: CGPoint(x: bounds.maxX, y: bounds.maxY))
            }
            let color = Color(hex: level < 0.20 ? 0xFFAA5E : 0x74FFCF)
            let progress = min(1, max(0, level))
            context.stroke(bottom, with: .color(color.opacity(0.12)), lineWidth: 2.4)
            guard progress > 0 else { return }
            let segment = bottom.trimmedPath(from: 0, to: progress)
            let stroke = StrokeStyle(lineWidth: 2.4, lineCap: .round)
            var halo = context
            halo.addFilter(.blur(radius: 7))
            halo.stroke(segment, with: .color(color.opacity(0.70)), lineWidth: 9)
            context.stroke(segment, with: .color(color.opacity(0.86)), style: stroke)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension Color {
    init(hex: Int) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
