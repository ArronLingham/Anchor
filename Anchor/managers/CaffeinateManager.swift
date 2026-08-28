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

import AppKit
import Combine
import CoreGraphics
import Defaults
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac awake, for a set time, until switched off, or for as long as
/// a *trigger* holds.
///
/// Held as an IOKit power assertion rather than by running `caffeinate`. The
/// assertion lives in the kernel: nothing polls, nothing is scheduled while it
/// is held, and there is no child process to supervise or leak. A timed session
/// costs exactly one timer, which fires once. The upstream implementation this
/// replaces spawned `caffeinate` and watched it with a repeating timer, which
/// both costs CPU and breaks this project's rule against sidecar processes.
///
/// ## Triggers
///
/// Three conditions can hold the assertion on their own: mains power, an
/// external display being attached, and a named app running. Each is driven by
/// a notification that already exists — `IOPSNotificationCreateRunLoopSource`
/// via `BatteryActivityManager`, `didChangeScreenParametersNotification`, and
/// `NSWorkspace`'s launch/terminate pair. **Nothing here polls.**
///
/// The manual switch and the triggers are deliberately separate pieces of
/// state. If they shared one flag, unplugging the charger would silently flip
/// the user's own toggle off, and toggling the switch off while plugged in
/// would appear not to work. They are OR-ed at the point the assertion is
/// taken, and only there.
@MainActor
final class CaffeinateManager: ObservableObject {
    static let shared = CaffeinateManager()

    /// Why the Mac is currently being kept awake. Empty means it is not.
    enum Reason: Hashable {
        case manual
        case onPower
        case externalDisplay
        case app(String)

        var label: String {
            switch self {
            case .manual: return String(localized: "switched on")
            case .onPower: return String(localized: "on power")
            case .externalDisplay: return String(localized: "external display")
            case .app(let name): return name
            }
        }
    }

    @Published private(set) var isActive = false
    /// When a timed session ends. Nil while indefinite or inactive.
    @Published private(set) var endsAt: Date?
    /// Every reason currently holding the assertion, for the UI to explain
    /// itself. A user who did not switch it on should be able to find out why
    /// their Mac is not sleeping.
    @Published private(set) var reasons: Set<Reason> = []

    private var assertionID: IOPMAssertionID = 0
    private var expiryTimer: DispatchSourceTimer?
    private var jiggleTimer: DispatchSourceTimer?

    private var manualActive = false
    private var triggerReasons: Set<Reason> = []

    private var monitoringInstalled = false
    private var batteryObserverID: Int?
    private var cancellables = Set<AnyCancellable>()
    private var isPluggedIn = false

    private init() {}

    // MARK: - Manual control

    /// Start keeping the Mac awake. `duration` of nil runs until stopped.
    ///
    /// Calling this while already active replaces the previous session, so a
    /// second request cannot leak the first assertion.
    func activate(for duration: TimeInterval? = nil) {
        manualActive = true

        guard let duration, duration > 0 else {
            expiryTimer?.cancel()
            expiryTimer = nil
            endsAt = nil
            syncAssertion()
            return
        }

        endsAt = Date().addingTimeInterval(duration)
        syncAssertion()
        scheduleExpiry(after: duration)
    }

    func deactivate() {
        manualActive = false
        expiryTimer?.cancel()
        expiryTimer = nil
        endsAt = nil
        syncAssertion()
    }

    func toggle(duration: TimeInterval? = nil) {
        manualActive ? deactivate() : activate(for: duration)
    }

    // MARK: - Triggers

    /// Installs the trigger observers. Safe to call more than once.
    ///
    /// Deferred rather than run from `init` — `BatteryActivityManager` is one
    /// of the singletons that must not be built while the run loop is still
    /// starting, and a `NSScreen.screens` read this early is needless work at
    /// launch. See the "never construct a singleton from AppDelegate's stored
    /// properties" note in CLAUDE.md.
    func startTriggerMonitoring() {
        guard !monitoringInstalled else { return }
        monitoringInstalled = true

        batteryObserverID = BatteryActivityManager.shared.addObserver { [weak self] event in
            guard case .powerSourceChanged(let plugged) = event else { return }
            Task { @MainActor in
                guard let self else { return }
                self.isPluggedIn = plugged
                self.evaluateTriggers()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateTriggers() }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluateTriggers() }
            }
        }

        // A trigger the user has just switched on should take effect without
        // waiting for the next power or display event.
        Defaults.publisher(keys: .caffeinateTriggerWhileOnPower,
                           .caffeinateTriggerWhileExternalDisplay)
            .sink { [weak self] _ in
                Task { @MainActor in self?.evaluateTriggers() }
            }
            .store(in: &cancellables)

        Defaults.publisher(.caffeinateTriggerApps)
            .sink { [weak self] _ in
                Task { @MainActor in self?.evaluateTriggers() }
            }
            .store(in: &cancellables)

        Defaults.publisher(.caffeinateJigglePointer)
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncJiggle() }
            }
            .store(in: &cancellables)

        isPluggedIn = Self.currentlyOnPower()
        evaluateTriggers()
    }

    /// Recomputes which triggers hold and takes or releases the assertion.
    func evaluateTriggers() {
        var found: Set<Reason> = []

        if Defaults[.caffeinateTriggerWhileOnPower], isPluggedIn {
            found.insert(.onPower)
        }

        if Defaults[.caffeinateTriggerWhileExternalDisplay], Self.hasExternalDisplay() {
            found.insert(.externalDisplay)
        }

        let wanted = Set(Defaults[.caffeinateTriggerApps])
        if !wanted.isEmpty {
            for app in NSWorkspace.shared.runningApplications {
                guard let bundleID = app.bundleIdentifier, wanted.contains(bundleID) else {
                    continue
                }
                found.insert(.app(app.localizedName ?? bundleID))
            }
        }

        guard found != triggerReasons else { return }
        triggerReasons = found
        syncAssertion()
    }

    /// True when a display other than the built-in panel is attached.
    ///
    /// Screens are matched by `NSScreenNumber` through `CGDisplayIsBuiltin`
    /// rather than by name, because localised names are not stable and a
    /// second identical monitor would collide.
    private static func hasExternalDisplay() -> Bool {
        NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) == 0
        }
    }

    private static func currentlyOnPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
                  as? [CFTypeRef]
        else { return false }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                  let state = info[kIOPSPowerSourceStateKey] as? String
            else { continue }
            if state == kIOPSACPowerValue { return true }
        }
        return false
    }

    // MARK: - Assertion

    /// The single place the assertion is taken or dropped. Everything else
    /// sets state and calls this.
    private func syncAssertion() {
        let wanted = manualActive || !triggerReasons.isEmpty

        var combined = triggerReasons
        if manualActive { combined.insert(.manual) }
        if combined != reasons { reasons = combined }

        if wanted {
            // Re-take when the assertion *type* no longer matches the
            // preference, so flipping "keep the display on too" takes effect
            // without the user switching the whole thing off and on.
            if assertionID != 0, heldType == desiredType {
                if !isActive { isActive = true }
                syncJiggle()
                return
            }
            releaseAssertion()
            takeAssertion()
        } else {
            releaseAssertion()
            if isActive { isActive = false }
        }
        syncJiggle()
    }

    private var desiredType: String {
        // Display sleep is the stronger of the two — holding it implies the
        // system stays up — so the preference picks which one is taken rather
        // than taking both.
        Defaults[.caffeinateKeepsDisplayAwake]
            ? kIOPMAssertionTypeNoDisplaySleep
            : kIOPMAssertionTypeNoIdleSleep
    }

    private var heldType: String?

    private func takeAssertion() {
        let type = desiredType
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Anchor: keeping this Mac awake" as CFString,
            &id)

        guard result == kIOReturnSuccess else {
            NSLog("CaffeinateManager: could not create power assertion (\(result))")
            return
        }

        assertionID = id
        heldType = type
        if !isActive { isActive = true }
    }

    /// Call after changing `caffeinateKeepsDisplayAwake` so the held assertion
    /// swaps type in place.
    func refreshAssertionType() {
        guard assertionID != 0 else { return }
        syncAssertion()
    }

    // MARK: - Internals

    /// One-shot. A repeating timer here would keep waking the machine that this
    /// feature exists to keep awake, for no reason after it has fired.
    private func scheduleExpiry(after duration: TimeInterval) {
        expiryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + duration, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.deactivate()
        }
        expiryTimer = timer
        timer.resume()
    }

    private func releaseAssertion() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        heldType = nil
    }

    // MARK: - Pointer jiggle

    /// A power assertion tells *macOS* not to sleep. It says nothing to Slack,
    /// Teams or a remote-desktop host, which decide you are away from real HID
    /// activity. This posts the smallest event that counts as activity.
    ///
    /// Off by default, and only ever runs while the assertion is held, so an
    /// idle Anchor schedules nothing. 59 s rather than 60 so it does not sit
    /// permanently in phase with other minute-aligned work.
    private func syncJiggle() {
        let wanted = isActive && Defaults[.caffeinateJigglePointer]
        if wanted {
            guard jiggleTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 59, repeating: 59, leeway: .seconds(5))
            timer.setEventHandler { MainActor.assumeIsolated { Self.jigglePointer() } }
            jiggleTimer = timer
            timer.resume()
        } else {
            jiggleTimer?.cancel()
            jiggleTimer = nil
        }
    }

    /// Moves the pointer one point and straight back.
    ///
    /// Posted as a real `mouseMoved` event rather than
    /// `CGWarpMouseCursorPosition`, because a warp relocates the cursor without
    /// generating an event and so does not reset anyone's idle timer — which is
    /// the entire point. Needs Accessibility; without it `post` is dropped and
    /// this is simply a no-op.
    private static func jigglePointer() {
        let origin = CGEvent(source: nil)?.location ?? .zero
        let nudged = CGPoint(x: origin.x + 1, y: origin.y)

        for point in [nudged, origin] {
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left)
            else { return }
            event.post(tap: .cghidEventTap)
        }
    }
}
