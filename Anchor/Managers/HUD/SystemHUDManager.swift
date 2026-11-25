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

import AnchorUtilities
import AppKit
import Combine
import Defaults

struct HUDControls: OptionSet {
    let rawValue: Int
    static let volume = Self(rawValue: 1 << 0)
    static let brightness = Self(rawValue: 1 << 1)
    static let backlight = Self(rawValue: 1 << 2)
    static let all: Self = [.volume, .brightness, .backlight]
}

struct HUDControlPlan: Equatable {
    enum Presentation: Equatable {
        case notch, floating, vertical, circular

        static var current: Self? {
            if Defaults[.enableCircularHUD] { return .circular }
            if Defaults[.enableVerticalHUD] { return .vertical }
            if Defaults[.enableCustomOSD] { return .floating }
            if Defaults[.enableSystemHUD] { return .notch }
            return nil
        }

        var controls: HUDControls {
            let floating = self == .floating
            var controls: HUDControls = []
            if floating ? Defaults[.enableOSDVolume] : Defaults[.enableVolumeHUD] {
                controls.insert(.volume)
            }
            if floating ? Defaults[.enableOSDBrightness] : Defaults[.enableBrightnessHUD] {
                controls.insert(.brightness)
            }
            if floating ? Defaults[.enableOSDKeyboardBacklight] : Defaults[.enableKeyboardBacklightHUD] {
                controls.insert(.backlight)
            }
            return controls
        }
    }

    let presentation: Presentation?
    let displayed: HUDControls
    let local: HUDControls

    init(presentation: Presentation?, displayed: HUDControls, externalDisplay: Bool,
         externalVolume: Bool, utilityOwners: Set<String>) {
        self.presentation = presentation
        self.displayed = presentation == nil ? [] : displayed
        var local = self.displayed
        if externalDisplay || utilityOwners.contains("brightness") { local.remove([.brightness, .backlight]) }
        if externalVolume || utilityOwners.contains("volumeKeys") { local.remove(.volume) }
        if utilityOwners.contains("notch") { local = [] }
        self.local = local
    }

    func suppressesNativeOSD(tapAvailable: Bool) -> Bool {
        // OSDUIHelper services all three controls. A partial replacement must
        // leave it running so every control outside Anchor can still show feedback.
        tapAvailable && local == .all
    }
}

@MainActor
final class SystemHUDManager {
    static let shared = SystemHUDManager()

    private var changesObserver: SystemChangesObserver?
    private weak var coordinator: AnchorViewCoordinator?
    private var appliedPlan: HUDControlPlan?
    private var suppressionEnabled: Bool?
    private var presentationGeneration = UUID()
    private var reconciliation: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func setup(coordinator: AnchorViewCoordinator) {
        self.coordinator = coordinator
        guard cancellables.isEmpty else { return }

        let keys: [Defaults.Key<Bool>] = [
            .enableSystemHUD, .enableCustomOSD, .enableVerticalHUD, .enableCircularHUD,
            .enableVolumeHUD, .enableBrightnessHUD, .enableKeyboardBacklightHUD,
            .enableOSDVolume, .enableOSDBrightness, .enableOSDKeyboardBacklight,
            .treatFunctionKeysAsVolume, .treatFunctionKeysAsBrightness,
            .enableThirdPartyDDCIntegration, .enableExternalVolumeControlListener
        ]
        for key in keys {
            Defaults.publisher(key, options: []).sink { [weak self] _ in self?.requestReconciliation() }
                .store(in: &cancellables)
        }
        Defaults.publisher(.thirdPartyDDCProvider, options: [])
            .sink { [weak self] _ in self?.requestReconciliation() }.store(in: &cancellables)
        Publishers.Merge(
            BetterDisplayManager.shared.$isRunning.removeDuplicates().dropFirst(),
            LunarManager.shared.$isRunning.removeDuplicates().dropFirst()
        )
        .sink { [weak self] _ in
            guard Defaults[.enableThirdPartyDDCIntegration] else { return }
            self?.requestReconciliation()
        }
        .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .utilityControlOwnershipChanged)
            .sink { [weak self] _ in self?.requestReconciliation() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .mediaKeyInterceptionAvailabilityDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileSuppression() }.store(in: &cancellables)
        reconcile()
    }

    nonisolated private func requestReconciliation() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { scheduleReconciliation() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.scheduleReconciliation() }
        }
    }

    private func scheduleReconciliation() {
        presentationGeneration = UUID()
        changesObserver?.invalidatePendingDeliveries()
        guard reconciliation == nil else { return }
        reconciliation = Task { [weak self] in
            guard let self else { return }
            self.reconciliation = nil
            self.reconcile()
        }
    }

    private func reconcile() {
        guard let coordinator else { return }
        let presentation = HUDControlPlan.Presentation.current
        let displayed = presentation?.controls ?? []
        let externalDisplay: Bool
        if !displayed.isEmpty, Defaults[.enableThirdPartyDDCIntegration] {
            switch Defaults[.thirdPartyDDCProvider] {
            case .betterDisplay: externalDisplay = BetterDisplayManager.checkRunning()
            case .lunar: externalDisplay = LunarManager.checkRunning()
            }
        } else {
            externalDisplay = false
        }
        let plan = HUDControlPlan(presentation: presentation, displayed: displayed,
                                  externalDisplay: externalDisplay,
                                  externalVolume: externalDisplay && Defaults[.enableExternalVolumeControlListener],
                                  utilityOwners: UtilityWorkspace.shared.controlOwners)
        if let previous = appliedPlan, let style = previous.presentation {
            let retired = previous.presentation == plan.presentation
                ? previous.displayed.subtracting(plan.displayed) : previous.displayed
            if !retired.isEmpty { dismiss(retired, style: style, coordinator: coordinator) }
        }
        appliedPlan = plan

        if plan.local.isEmpty {
            changesObserver?.stopObserving()
            changesObserver = nil
        } else {
            if changesObserver == nil {
                changesObserver = SystemChangesObserver()
            }
            changesObserver?.update(controls: plan.local)
        }
        reconcileSuppression()
    }

    private func reconcileSuppression() {
        let wanted = appliedPlan?.suppressesNativeOSD(
            tapAvailable: changesObserver?.isInterceptionAvailable ?? false) ?? false
        guard wanted != suppressionEnabled else { return }
        suppressionEnabled = wanted
        if wanted { SystemOSDManager.disableSystemHUD() }
        else { SystemOSDManager.enableSystemHUD() }
    }

    private func dismiss(_ controls: HUDControls, style: HUDControlPlan.Presentation, coordinator: AnchorViewCoordinator) {
        switch style {
        case .notch:
            guard coordinator.sneakPeek.show, !controls.intersection(Self.control(for: coordinator.sneakPeek.type)).isEmpty else { return }
            let type = coordinator.sneakPeek.type
            coordinator.toggleSneakPeek(status: false, type: type) { [weak coordinator] in
                coordinator?.sneakPeek.type == type
            }
        case .floating: CustomOSDWindowManager.shared.dismiss(controls)
        case .vertical: VerticalHUDWindowManager.shared.dismiss(controls)
        case .circular: CircularHUDWindowManager.shared.dismiss(controls)
        }
    }

    static func control(for type: SneakContentType) -> HUDControls {
        switch type {
        case .volume: return .volume
        case .brightness, .contrast: return .brightness
        case .backlight: return .backlight
        default: return []
        }
    }

    func present(type: SneakContentType, value: CGFloat, icon: String = "", onScreen screen: NSScreen? = nil) {
        let control = Self.control(for: type)
        guard !control.isEmpty, let style = HUDControlPlan.Presentation.current, style.controls.contains(control)
        else { return }
        if type == .volume, HUDSuppressionCoordinator.shared.shouldSuppressVolumeHUD { return }
        switch style {
        case .notch:
            let generation = presentationGeneration
            let notchIcon = type == .volume && icon.isEmpty && BluetoothAudioManager.shared.activeDeviceIconSymbol() != nil
                ? (value > 0 ? "headphones" : "headphones.slash")
                : icon
            coordinator?.toggleSneakPeek(status: true, type: type, value: value, icon: notchIcon, onScreen: screen) { [weak self] in
                self?.presentationGeneration == generation
            }
        case .floating:
            CustomOSDWindowManager.shared.show(type: type, value: value, icon: icon, onScreen: screen)
        case .vertical:
            VerticalHUDWindowManager.shared.show(type: type, value: value, icon: icon, onScreen: screen)
        case .circular:
            CircularHUDWindowManager.shared.show(type: type, value: value, icon: icon, onScreen: screen)
        }
    }
}
