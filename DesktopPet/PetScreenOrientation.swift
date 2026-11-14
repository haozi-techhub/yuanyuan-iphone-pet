import OSLog
import SwiftUI
import UIKit

enum PetScreenOrientation: String, CaseIterable, Identifiable {
    case automatic
    case portrait
    case landscapeLeft
    case landscapeRight

    static let storageKey = "pet.screenOrientation"

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "自动旋转"
        case .portrait: "竖屏"
        case .landscapeLeft: "向左横屏"
        case .landscapeRight: "向右横屏"
        }
    }

    fileprivate var mask: UIInterfaceOrientationMask {
        switch self {
        case .automatic: .allButUpsideDown
        case .portrait: .portrait
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        }
    }
}

final class PetAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        let savedValue = UserDefaults.standard.string(forKey: PetScreenOrientation.storageKey)
        return (savedValue.flatMap(PetScreenOrientation.init(rawValue:)) ?? .automatic).mask
    }
}

struct PetOrientationPreference: UIViewRepresentable {
    @Environment(\.scenePhase) private var scenePhase

    let orientation: PetScreenOrientation

    func makeUIView(context: Context) -> OrientationView {
        let view = OrientationView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: OrientationView, context: Context) {
        view.update(orientation, active: scenePhase == .active)
    }

    final class OrientationView: UIView {
        private var orientation = PetScreenOrientation.automatic
        private var active = false
        private var updatePending = false

        func update(_ orientation: PetScreenOrientation, active: Bool) {
            guard self.orientation != orientation || self.active != active else { return }
            self.orientation = orientation
            self.active = active
            applyPreference()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyPreference()
        }

        private func applyPreference() {
            guard active, window != nil, !updatePending else { return }
            updatePending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                updatePending = false
                guard active, let window, let scene = window.windowScene else { return }

                // A presented settings sheet can participate in orientation decisions.
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }

                scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation.mask)) { error in
                    Logger(subsystem: "com.haozi.desktoppet", category: "Orientation")
                        .debug("Scene orientation request declined: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
