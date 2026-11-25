/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import CoreGraphics
import Defaults
import AppKit
import AVFoundation
import AnchorUtilities

final class SystemChangesObserver: MediaKeyInterceptorDelegate {
    private var volumeController: SystemVolumeController { .shared }
    private var brightnessController: SystemBrightnessController { .shared }
    private var keyboardBacklightController: SystemKeyboardBacklightController { .shared }
    private let mediaKeyInterceptor = MediaKeyInterceptor.shared
    private let volumeFeedbackPlayer = VolumeFeedbackPlayer.shared

    private static let headsetIconSymbols: Set<String> = [
        "airpods",
        "airpodspro",
        "airpodsmax",
        "beats.headphones",
        "headphones"
    ]

    private var standardVolumeStep: Float {
        Float(Defaults[.volumeStepPercent]) / 100.0
    }
    private var fineVolumeStep: Float {
        Float(Defaults[.volumeFineStepPercent]) / 100.0
    }
    private var standardBrightnessStep: Float {
        Float(Defaults[.brightnessStepPercent]) / 100.0
    }
    private var fineBrightnessStep: Float {
        Float(Defaults[.brightnessFineStepPercent]) / 100.0
    }

    private var controls: HUDControls = []
    private var deliveriesValid = false
    private var volumeEnabled: Bool { deliveriesValid && controls.contains(.volume) }
    private var brightnessEnabled: Bool { deliveriesValid && controls.contains(.brightness) }
    private var keyboardBacklightEnabled: Bool { deliveriesValid && controls.contains(.backlight) }

    var isInterceptionAvailable: Bool { mediaKeyInterceptor.isInterceptionAvailable }

    func invalidatePendingDeliveries() {
        deliveriesValid = false
        mediaKeyInterceptor.invalidatePendingCommands()
    }

    func update(controls: HUDControls) {
        let oldControls = self.controls
        self.controls = controls
        deliveriesValid = true

        if oldControls.contains(.volume) != controls.contains(.volume) {
            if controls.contains(.volume) {
                volumeController.onVolumeChange = { [weak self] volume, muted in
                    self?.sendVolumeNotification(value: muted ? 0 : volume, isMuted: muted)
                }
                volumeController.onRouteChange = { [weak self] in
                    guard let self, self.volumeEnabled else { return }
                    let muted = self.volumeController.isMuted
                    self.sendVolumeNotification(value: muted ? 0 : self.volumeController.currentVolume, isMuted: muted)
                }
                volumeController.start()
            } else {
                volumeController.onVolumeChange = nil
                volumeController.onRouteChange = nil
            }
        }

        if oldControls.contains(.brightness) != controls.contains(.brightness) {
            if controls.contains(.brightness) {
                brightnessController.onBrightnessChange = { [weak self] value in
                    guard let self, self.brightnessEnabled else { return }
                    MainActor.assumeIsolated { SystemHUDManager.shared.present(type: .brightness, value: CGFloat(value)) }
                }
                brightnessController.start()
            } else {
                // Accepted brightness changes and independent Dashboard/preview
                // users still own their own controller work.
                brightnessController.onBrightnessChange = nil
            }
        }

        if oldControls.contains(.backlight) != controls.contains(.backlight) {
            if controls.contains(.backlight) {
                keyboardBacklightController.onBacklightChange = { [weak self] value in
                    guard let self, self.keyboardBacklightEnabled else { return }
                    MainActor.assumeIsolated { SystemHUDManager.shared.present(type: .backlight, value: CGFloat(value)) }
                }
                keyboardBacklightController.start()
            } else {
                keyboardBacklightController.onBacklightChange = nil
            }
        }

        if controls.isEmpty {
            mediaKeyInterceptor.delegate = nil
            mediaKeyInterceptor.configuration = .disabled
            mediaKeyInterceptor.stop()
        } else {
            mediaKeyInterceptor.delegate = self
            mediaKeyInterceptor.configuration = MediaKeyConfiguration(
                interceptVolume: controls.contains(.volume),
                interceptBrightness: controls.contains(.brightness),
                interceptCommandModifiedBrightness: controls.contains(.backlight),
                interceptFunctionKeysAsBrightness: Defaults[.treatFunctionKeysAsBrightness],
                interceptFunctionKeysAsVolume: Defaults[.treatFunctionKeysAsVolume]
            )
            if oldControls.isEmpty { mediaKeyInterceptor.start() }
        }
    }

    func stopObserving() {
        invalidatePendingDeliveries()
        update(controls: [])
    }

    // MARK: - MediaKeyInterceptorDelegate

    func mediaKeyInterceptor(
        _ interceptor: MediaKeyInterceptor,
        didReceiveVolumeCommand direction: MediaKeyDirection,
        step: MediaKeyStep,
        isRepeat: Bool,
        modifiers: NSEvent.ModifierFlags
    ) {
        guard volumeEnabled else { return }
        SystemOSDManager.suppressNativeOSDNow()
        
        // Elastic Limit Detection (Vertical HUD)
        if HUDControlPlan.Presentation.current == .vertical {
            let volume = volumeController.currentVolume
            if direction == .up && volume >= 0.99 {
                MainActor.assumeIsolated { VerticalHUDWindowManager.shared.triggerBump(direction: 1) }
            } else if direction == .down && volume <= 0.01 {
                MainActor.assumeIsolated { VerticalHUDWindowManager.shared.triggerBump(direction: -1) }
            }
        }
        
        let baseStep = volumeStep(for: step)
        let delta = direction == .up ? baseStep : -baseStep
        volumeController.adjust(by: delta)
        volumeFeedbackPlayer.playIfNeeded()
    }

    func mediaKeyInterceptorDidToggleMute(_ interceptor: MediaKeyInterceptor) {
        guard volumeEnabled else { return }
        SystemOSDManager.suppressNativeOSDNow()
        volumeController.toggleMute()
    }

    func mediaKeyInterceptor(
        _ interceptor: MediaKeyInterceptor,
        didReceiveBrightnessCommand direction: MediaKeyDirection,
        step: MediaKeyStep,
        isRepeat: Bool,
        modifiers: NSEvent.ModifierFlags
    ) {
        let isBacklight = modifiers.contains(.command) && keyboardBacklightEnabled
        guard isBacklight || brightnessEnabled else { return }
        SystemOSDManager.suppressNativeOSDNow()

        // Elastic Limit Detection (Vertical HUD)
        if HUDControlPlan.Presentation.current == .vertical {
            if isBacklight {
                let brightness = keyboardBacklightController.currentLevel
                if direction == .up && brightness >= 0.99 {
                    MainActor.assumeIsolated { VerticalHUDWindowManager.shared.triggerBump(direction: 1) }
                } else if direction == .down && brightness <= 0.01 {
                    MainActor.assumeIsolated { VerticalHUDWindowManager.shared.triggerBump(direction: -1) }
                }
            } else {
                let brightness = brightnessController.currentBrightness
                if direction == .up && brightness >= 0.99 {
                    MainActor.assumeIsolated { VerticalHUDWindowManager.shared.triggerBump(direction: 1) }
                } else if direction == .down && brightness <= 0.01 {
                    MainActor.assumeIsolated { VerticalHUDWindowManager.shared.triggerBump(direction: -1) }
                }
            }
        }
        
        let baseStep = brightnessStep(for: step)
        let delta = direction == .up ? baseStep : -baseStep
        if isBacklight {
            keyboardBacklightController.adjust(by: delta)
        } else {
            brightnessController.adjust(by: delta)
        }
    }

    // MARK: - HUD Dispatch

    private func sendVolumeNotification(value: Float, isMuted: Bool) {
        guard volumeEnabled, !HUDSuppressionCoordinator.shared.shouldSuppressVolumeHUD else { return }
        MainActor.assumeIsolated {
            let icon = HUDControlPlan.Presentation.current == .vertical ? resolvedVolumeIcon(isMuted: isMuted) : ""
            SystemHUDManager.shared.present(type: .volume, value: CGFloat(value), icon: icon)
        }
    }

    @MainActor
    private func resolvedVolumeIcon(isMuted: Bool) -> String {
        guard let icon = BluetoothAudioManager.shared.activeDeviceIconSymbol() else { return "" }
        if isMuted && Self.headsetIconSymbols.contains(icon) {
            return "headphones.slash"
        }
        return icon
    }


}

private extension SystemChangesObserver {
    func volumeStep(for step: MediaKeyStep) -> Float {
        switch step {
        case .standard:
            return standardVolumeStep
        case .fine:
            return fineVolumeStep
        }
    }

    func brightnessStep(for step: MediaKeyStep) -> Float {
        switch step {
        case .standard:
            return standardBrightnessStep
        case .fine:
            return fineBrightnessStep
        }
    }
}

private final class VolumeFeedbackPlayer {
    static let shared = VolumeFeedbackPlayer()

    private let queue = DispatchQueue(label: "com.dynamicisland.volume-feedback-player")
    private var player: AVAudioPlayer?
    private var lastPlayDate: Date = .distantPast
    private let minimumInterval: TimeInterval = 0.08
    private var didLogMissingAsset = false

    private init() {}

    func playIfNeeded() {
        guard Defaults[.playVolumeChangeFeedback] else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastPlayDate) >= self.minimumInterval else { return }
            self.lastPlayDate = now
            self.preparePlayerIfNeeded()
            guard let player = self.player else { return }
            player.currentTime = 0
            player.play()
        }
    }

    private func preparePlayerIfNeeded() {
        if player != nil { return }
        guard let url = Bundle.main.url(forResource: "audio-feedback", withExtension: "m4a") else {
            if !didLogMissingAsset {
                NSLog("⚠️ audio-feedback.m4a is missing from the app bundle; volume feedback disabled.")
                didLogMissingAsset = true
            }
            return
        }

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.volume = 1
            audioPlayer.prepareToPlay()
            player = audioPlayer
        } catch {
            if !didLogMissingAsset {
                NSLog("⚠️ Failed to initialize volume feedback player: \(error.localizedDescription)")
                didLogMissingAsset = true
            }
        }
    }
}
