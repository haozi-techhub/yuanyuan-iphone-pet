import SwiftUI

nonisolated enum PetEyelid {
    static func outline(openness: CGFloat, bend: CGFloat, widthScale: CGFloat,
                        strokeWeight: CGFloat) -> Path {
        let curvedLid = min(1, max(0, (abs(bend) - 0.35) / 0.45))
        let openLimit = 0.43 + curvedLid * 0.08
        let closedLimit = 0.19 + curvedLid * 0.13
        let closed = smooth((openLimit - openness) / (openLimit - closedLimit))
        // Fill out every curved lid as it closes, including curves set by animation keyframes.
        let fullness = smooth(abs(bend) / 0.30)
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
        return Path { path in
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
    }

    private static func smooth(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}

private struct PetCompanionEyelid: Shape {
    var openness: CGFloat
    var smile: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(openness, smile) }
        set { (openness, smile) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        PetEyelid.outline(openness: max(0.14, openness), bend: (-25.0 / 85) * smile,
                          widthScale: 1, strokeWeight: 6.8 + 6.4 * smile)
            .applying(CGAffineTransform(scaleX: rect.width / 70, y: rect.width / 70)
                .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
    }
}

struct PetCompanionEye: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let width: CGFloat
    let gaze: CGFloat
    var openness: CGFloat = 1
    var animatesGaze = true
    var smiles = false

    var body: some View {
        PetCompanionEyelid(openness: smiles ? 0.17 : openness, smile: smiles ? 1 : 0)
            .fill(.white)
            .frame(width: width, height: width * 106 / 70)
            .scaleEffect(x: 1 - abs(gaze) * 0.07, y: 1)
            .rotationEffect(.degrees(gaze * 4))
            .offset(x: gaze * width * 0.14)
            .animation(reduceMotion || !animatesGaze ? nil : .easeInOut(duration: 0.36), value: gaze)
            .animation(reduceMotion || !animatesGaze ? nil : .spring(duration: 0.36, bounce: 0.16), value: openness)
            .animation(reduceMotion ? nil : .spring(duration: 0.36, bounce: 0.16), value: smiles)
            .accessibilityHidden(true)
    }
}

struct PetCompanionEyes: View {
    let eyeWidth: CGFloat
    let gaze: CGFloat
    var openness: CGFloat = 1
    var animatesGaze = true
    var reaction: PetLiveActivityAttributes.ContentState.Reaction?

    var body: some View {
        HStack(spacing: eyeWidth * 0.7) {
            PetCompanionEye(width: eyeWidth, gaze: gaze, openness: reaction == .curious ? 0.74 : openness,
                            animatesGaze: animatesGaze, smiles: reaction == .happy)
            PetCompanionEye(width: eyeWidth, gaze: gaze, openness: reaction == .curious ? 1.08 : openness,
                            animatesGaze: animatesGaze, smiles: reaction == .happy || reaction == .wink)
        }
    }
}

struct PetCompanionCard: View {
    let name: String
    let status: String
    let hasMessage: Bool
    let gaze: CGFloat
    var openness: CGFloat = 1
    var animatesGaze = true

    static let background = Color(red: 0.12, green: 0.09, blue: 0.20)

    var body: some View {
        HStack(spacing: 14) {
            PetCompanionEyes(eyeWidth: 14, gaze: gaze, openness: openness, animatesGaze: animatesGaze)
            .frame(width: 76, height: 54)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [Color(red: 0.31, green: 0.21, blue: 0.46), .black],
                                         startPoint: .top, endPoint: .bottom))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(hasMessage ? Color(red: 1, green: 0.83, blue: 0.48) : Color.white.opacity(0.76))
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)
            if hasMessage {
                Image(systemName: "envelope.fill")
                    .font(.callout)
                    .foregroundStyle(Color(red: 1, green: 0.83, blue: 0.48))
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
    }
}
