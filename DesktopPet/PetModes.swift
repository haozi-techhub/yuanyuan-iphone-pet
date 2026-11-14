import SwiftUI
import UIKit

enum PetMode: String, CaseIterable, Identifiable {
    case normal, companion, battery, nightLight

    var id: Self { self }

    var title: String {
        switch self {
        case .normal: "普通"
        case .companion: "陪伴"
        case .battery: "电量宠物"
        case .nightLight: "夜灯"
        }
    }
}

@Observable
@MainActor
final class PetModes {
    static let timerOptions = [0, 15, 30, 60]

    @ObservationIgnored var onReaction: ((PetExpression) -> Void)?
    @ObservationIgnored var onBatteryStateChanged: (() -> Void)?
    private(set) var nightLightExpired = false
    private(set) var batteryLevel: Double?
    private var mode = PetMode.normal
    private var batteryState: UIDevice.BatteryState = .unknown
    @ObservationIgnored private var reachedFullWhileConnected = false
    private var timerMinutes = 0
    private var nightStarted: TimeInterval = 0
    private var nightDeadline: TimeInterval?
    @ObservationIgnored private var nextHungryAt: TimeInterval?
    @ObservationIgnored private var batteryObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var previousBatteryMonitoring: Bool?
    @ObservationIgnored private weak var screen: UIScreen?
    @ObservationIgnored private var savedBrightness: CGFloat?
    private var active = false
    @ObservationIgnored private var keepAwake = false
    @ObservationIgnored private var expressionShowActive = false
    @ObservationIgnored private var marchActive = false

    var baseline: PetExpression? {
        if mode == .nightLight { return nightLightExpired ? .sleepy : nil }
        guard active, mode == .battery else { return nil }
        if isCharging { return .charging }
        if isFullyCharged { return nil }
        return batteryLevel.map { $0 < 0.10 } == true ? .sleepy : nil
    }

    var caption: String? {
        mode == .nightLight && nightLightExpired ? "夜灯定时已结束" : nil
    }

    var isCharging: Bool { active && mode == .battery && batteryState == .charging }
    var isFullyCharged: Bool { active && mode == .battery && batteryState == .full }

    private var batteryPercentage: Int? { batteryLevel.map { Int(($0 * 100).rounded()) } }

    var batteryCaption: String? {
        guard active, mode == .battery else { return nil }
        let percentage = batteryPercentage.map { "饱腹度 \($0)%" }
        if isCharging { return percentage.map { "充电中 · \($0)" } ?? "充电中" }
        if isFullyCharged { return percentage.map { "充满电 · \($0)" } ?? "充满电" }
        return percentage ?? "饱腹度未知"
    }

    var batteryVoiceReply: String {
        guard mode == .battery else { return "切到电量宠物，我就能告诉你电量啦。" }
        guard active else { return "我暂时读不到电量。" }
        let percentage = batteryPercentage.map { "现在电量百分之\($0)。" }
        switch batteryState {
        case .charging: return "我还在充电。" + (percentage ?? "")
        case .full: return "我已经充满啦！"
        case .unplugged: return "现在没在充电。" + (percentage ?? "我暂时读不到电量。")
        default: return (percentage ?? "我暂时读不到电量。") + "充电状态暂时未知。"
        }
    }

    var sensorsSuppressed: Bool { mode == .nightLight }
    var eyeTint: Color? { mode == .nightLight ? Color(red: 1, green: 0.70, blue: 0.35) : nil }
    var glowTint: Color? { mode == .nightLight ? Color(red: 1, green: 0.51, blue: 0.20) : nil }

    func configure(mode: PetMode, timerMinutes: Int, active: Bool, keepAwake: Bool, screen: UIScreen? = nil) {
        let modeChanged = self.mode != mode
        let timer = Self.timerOptions.contains(timerMinutes) ? timerMinutes : 0
        let timerChanged = self.timerMinutes != timer
        let uptime = ProcessInfo.processInfo.systemUptime

        if self.screen !== screen || !active || mode != .nightLight {
            restoreBrightness()
        }
        self.screen = screen
        self.active = active
        self.keepAwake = keepAwake
        self.mode = mode
        self.timerMinutes = timer

        if mode == .nightLight {
            if modeChanged || timerChanged { startNightLight(at: uptime) }
            updateNightLight(at: uptime)
        } else if modeChanged {
            nightDeadline = nil
            nightLightExpired = false
        }

        if active && mode == .battery {
            startBatteryMonitoring()
        } else {
            stopBatteryMonitoring()
            if modeChanged {
                batteryLevel = nil
                batteryState = .unknown
                reachedFullWhileConnected = false
                nextHungryAt = nil
            }
        }
        applyIdleTimer()
    }

    func restartNightLight(minutes: Int) {
        guard mode == .nightLight, Self.timerOptions.contains(minutes) else { return }
        timerMinutes = minutes
        let uptime = ProcessInfo.processInfo.systemUptime
        startNightLight(at: uptime)
        updateNightLight(at: uptime)
        applyIdleTimer()
    }

    func tick(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard active else { return }
        if mode == .nightLight {
            updateNightLight(at: uptime)
        } else if mode == .battery {
            guard batteryState == .unplugged, let batteryLevel, (0.10..<0.20).contains(batteryLevel) else {
                nextHungryAt = nil
                return
            }
            if uptime >= (nextHungryAt ?? uptime) {
                nextHungryAt = uptime + 20
                onReaction?(.hungry)
            }
        }
    }

    func brightness(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime, motionEnabled: Bool = true) -> CGFloat {
        switch mode {
        case .normal, .companion:
            return 1
        case .battery:
            guard batteryState != .charging, batteryState != .full, let batteryLevel else { return 1 }
            if batteryLevel < 0.10 { return 0.48 }
            return CGFloat(0.68 + 0.32 * min(1, max(0, (batteryLevel - 0.20) / 0.40)))
        case .nightLight:
            if nightLightExpired, let deadline = nightDeadline {
                guard motionEnabled else { return 0.17 }
                let fade = min(1, max(0, (uptime - deadline) / 2))
                return CGFloat(breathing(at: deadline) * (1 - fade) + 0.17 * fade)
            }
            return motionEnabled ? CGFloat(breathing(at: uptime)) : 0.76
        }
    }

    func stop() {
        active = false
        expressionShowActive = false
        marchActive = false
        restoreBrightness()
        stopBatteryMonitoring()
        applyIdleTimer()
    }

    func setExpressionShowActive(_ active: Bool) {
        guard expressionShowActive != active else { return }
        expressionShowActive = active
        if mode == .nightLight {
            if active {
                restoreBrightness()
            } else if self.active {
                updateNightLight(at: ProcessInfo.processInfo.systemUptime)
            }
        }
        applyIdleTimer()
    }

    func setMarchActive(_ active: Bool) {
        marchActive = active
        applyIdleTimer()
    }

    private func startNightLight(at uptime: TimeInterval) {
        nightStarted = uptime
        nightDeadline = timerMinutes == 0 ? nil : uptime + TimeInterval(timerMinutes * 60)
        nightLightExpired = false
    }

    private func updateNightLight(at uptime: TimeInterval) {
        if let deadline = nightDeadline, uptime >= deadline {
            if !nightLightExpired {
                nightLightExpired = true
                applyIdleTimer()
            }
            if uptime >= deadline + 2 { restoreBrightness() }
        } else if active, !expressionShowActive, savedBrightness == nil, let screen {
            savedBrightness = screen.brightness
            screen.brightness = min(screen.brightness, 0.25)
        }
    }

    private func breathing(at uptime: TimeInterval) -> Double {
        let phase = max(0, uptime - nightStarted).truncatingRemainder(dividingBy: 10)
        let progress = phase < 4 ? phase / 4 : (10 - phase) / 6
        return 0.60 + 0.34 * (1 - cos(.pi * progress)) / 2
    }

    private func restoreBrightness() {
        if let savedBrightness { screen?.brightness = savedBrightness }
        savedBrightness = nil
    }

    private func applyIdleTimer() {
        let modeKeepsAwake = mode == .nightLight ? !nightLightExpired : keepAwake
        UIApplication.shared.isIdleTimerDisabled = active && (expressionShowActive || marchActive || modeKeepsAwake)
    }

    private func startBatteryMonitoring() {
        guard batteryObservers.isEmpty else { return }
        let device = UIDevice.current
        previousBatteryMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshBattery() }
            }
            batteryObservers.append(observer)
        }
        refreshBattery(announceCompletion: false)
    }

    private func stopBatteryMonitoring() {
        guard let previousBatteryMonitoring else { return }
        for observer in batteryObservers { NotificationCenter.default.removeObserver(observer) }
        batteryObservers.removeAll()
        UIDevice.current.isBatteryMonitoringEnabled = previousBatteryMonitoring
        self.previousBatteryMonitoring = nil
    }

    private func refreshBattery(announceCompletion: Bool = true) {
        guard active, mode == .battery else { return }
        let device = UIDevice.current
        let previous = batteryState
        batteryState = device.batteryState
        let level = Double(device.batteryLevel)
        batteryLevel = (0...1).contains(level) ? level : nil
        let completed = announceCompletion && previous == .charging && isFullyCharged && !reachedFullWhileConnected
        if batteryState == .unplugged { reachedFullWhileConnected = false }
        if isFullyCharged { reachedFullWhileConnected = true }
        if previous != batteryState { onBatteryStateChanged?() }
        if completed { onReaction?(.charged) }
    }
}
