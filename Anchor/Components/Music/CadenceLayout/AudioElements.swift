/*
 * Cadence
 * Copyright (C) 2026 Cadence Contributors
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
import CoreAudio
import Defaults
import SwiftUI

// The four elements that used to draw an icon and do nothing.
//
// They were placeable, plausible-looking and inert — the dead-switch trap in a
// new costume, and worse than a missing feature because there is no error to
// find. Each is now its own view rather than a case in the big `switch`,
// because each needs its own observation and `PlayerElementView` is a value
// type recreated on every solve.

// `isLive` is false in the settings preview. Without it, arranging a layout
// ran real system work: the AirPlay element drove AppleScript against Music,
// and the output element made HAL round-trips — every time the preview
// re-rendered, which is on every drag frame.

/// Picks the Mac's output device.
struct OutputDeviceElement: View {
    let style: SurfaceStyle
    var isLive: Bool = true
    @ObservedObject private var routes = AudioRouteManager.shared

    var body: some View {
        Menu {
            ForEach(routes.devices) { device in
                Button {
                    routes.select(device: device)
                } label: {
                    Label(device.name, systemImage: device.iconName)
                }
            }
            if routes.devices.isEmpty { Text("No output devices") }
        } label: {
            Image(systemName: routes.activeDevice?.iconName ?? "speaker.wave.2")
                .font(.system(size: 13 * style.textScale, weight: .medium))
                .foregroundStyle(style.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(!isLive)
        // Refreshed when the element appears rather than on a timer. The manager
        // also listens to CoreAudio directly, so this only covers a change it
        // missed before the element existed.
        .onAppear { if isLive { routes.refreshDevices() } }
    }
}

/// Apple Music's own AirPlay routing.
///
/// A different mechanism from the output device above: this moves what *Music*
/// is playing, not what the Mac is playing, and it only means anything while
/// Music is the source. It is AppleScript-driven, hence the async refresh.
struct AirPlayElement: View {
    let style: SurfaceStyle
    var isLive: Bool = true
    @ObservedObject private var airplay = AppleMusicAirPlayManager.shared

    var body: some View {
        Menu {
            ForEach(airplay.devices) { device in
                Button {
                    Task { await airplay.toggleDevice(device) }
                } label: {
                    Label(
                        device.name,
                        systemImage: device.isSelected ? "checkmark.circle.fill" : device.iconName)
                }
            }
            if airplay.devices.isEmpty { Text("No AirPlay devices") }
        } label: {
            Image(systemName: "airplayaudio")
                .font(.system(size: 13 * style.textScale, weight: .medium))
                .foregroundStyle(
                    airplay.devices.contains(where: \.isSelected) ? style.accent : style.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(!isLive)
        .task { if isLive { await airplay.refreshDevices() } }
    }
}

/// System output volume.
/// The volume of the music app itself, over AppleScript.
///
/// Spotify, Music and Amazon Music all expose `sound volume` as 0-100. Sources
/// with no scriptable volume (Now Playing, YouTube Music) have no app volume to
/// set, so the element falls back to the system slider rather than pretending.
enum AppVolume {
    static func scriptTarget(for controller: MediaControllerType) -> String? {
        switch controller {
        case .appleMusic: return "Music"
        case .spotify: return "Spotify"
        case .amazonMusic: return "Amazon Music"
        default: return nil
        }
    }

    static func current(_ app: String) async -> Float? {
        guard
            let descriptor = try? await AppleScriptHelper.execute(
                "tell application \"\(app)\" to get sound volume")
        else { return nil }
        let value = descriptor.int32Value
        guard value >= 0, value <= 100 else { return nil }
        return Float(value) / 100
    }

    static func set(_ value: Float, app: String) {
        let level = Int((min(max(value, 0), 1) * 100).rounded())
        Task.detached(priority: .utility) {
            try? await AppleScriptHelper.executeVoid(
                "tell application \"\(app)\" to set sound volume to \(level)")
        }
    }
}

struct VolumeElement: View {
    let style: SurfaceStyle
    var isLive: Bool = true
    // Not `= SystemVolume.current()`. A `@State` initialiser runs every time
    // SwiftUI recreates the struct, so that made two blocking CoreAudio HAL
    // round-trips per render and discarded all but the first. Read in
    // `onAppear` instead, where it happens once.
    @State private var volume: Float = 0
    @Default(.volumeControlsApp) private var controlsApp
    @Default(.mediaController) private var source

    /// nil when the slider should drive the system instead — either the user
    /// asked for system volume, or the current source has no scriptable one.
    private var appTarget: String? {
        controlsApp ? AppVolume.scriptTarget(for: source) : nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: volume < 0.01 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 9 * style.textScale))
                .foregroundStyle(style.subtleInk)
            Slider(
                value: Binding(
                    get: { volume },
                    set: {
                        volume = $0
                        if let app = appTarget {
                            AppVolume.set($0, app: app)
                        } else {
                            SystemVolume.set($0)
                        }
                    }), in: 0...1
            )
            .controlSize(.mini)
            .tint(style.ink.opacity(0.85))
            .disabled(!isLive)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Read on appear, not polled. The slider is the source of truth while
        // the user is dragging it, and a poll would fight them for the handle.
        .onAppear {
            guard isLive else {
                volume = 0.6
                return
            }
            if let app = appTarget {
                // AppleScript is a round trip, so seed from the system value and
                // correct it when the app answers rather than blocking a render.
                volume = SystemVolume.current()
                Task { if let level = await AppVolume.current(app) { volume = level } }
            } else {
                volume = SystemVolume.current()
            }
        }
    }
}

/// Reading and writing the default output device's volume.
///
/// Deliberately CoreAudio rather than `osascript -e "set volume"`: that spawns
/// a process per change, and a slider produces dozens of changes per drag.
enum SystemVolume {
    private static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutableBytes(of: &id) { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size,
                buffer.baseAddress!)
        }
        return status == noErr ? id : nil
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    static func current() -> Float {
        guard let device = defaultOutputDevice() else { return 0 }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? Float(value) : 0
    }

    static func set(_ newValue: Float) {
        guard let device = defaultOutputDevice() else { return }
        var value = Float32(min(max(newValue, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        _ = withUnsafeBytes(of: &value) { buffer in
            AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, size, buffer.baseAddress!)
        }
    }
}

/// A countdown you can put on a surface.
///
/// Independent of playback, like `clock` — which is why both can sit on a
/// surface that is showing nothing playing without leaving a hole.
struct PlayerTimerElement: View {
    let style: SurfaceStyle
    var isLive: Bool = true
    @ObservedObject private var timer = PlayerTimer.shared

    var body: some View {
        Button {
            if isLive { timer.tap() }
        } label: {
            Text(isLive ? timer.display : "05:00")
                .font(.system(size: 13 * style.textScale, weight: .medium).monospacedDigit())
                .foregroundStyle(timer.isRunning ? style.accent : style.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach([1, 3, 5, 10, 15, 25, 45], id: \.self) { minutes in
                Button("\(minutes) min") { timer.start(minutes: minutes) }
            }
            Divider()
            Button("Reset") { timer.reset() }
        }
        // Reference-counted, the way `AudioTap` is. A countdown whose element
        // has been removed from every surface has nothing to display into, and
        // a timer ticking for a view that no longer exists is the "a loop that
        // no-ops is still a loop" trap.
        .onAppear { if isLive { timer.acquire() } }
        .onDisappear { if isLive { timer.release() } }
    }
}

/// The countdown itself.
///
/// One repeating timer, and **only while running** — a stopped countdown costs
/// nothing. It publishes once a second rather than per frame, which is all a
/// mm:ss readout can show.
@MainActor
final class PlayerTimer: ObservableObject {
    static let shared = PlayerTimer()

    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var isRunning = false

    private var ticker: Timer?
    private var consumers = 0

    private init() {}

    /// A surface is showing the timer element.
    func acquire() { consumers += 1 }

    /// One fewer surface is showing it. At zero the countdown stops and clears:
    /// there is nowhere left to display it, and a hidden timer that fires later
    /// would be a surprise rather than a feature.
    func release() {
        consumers = max(0, consumers - 1)
        if consumers == 0 { reset() }
    }

    var display: String {
        remaining <= 0 ? "--:--" : PlayerElementView.timestamp(remaining)
    }

    func start(minutes: Int) {
        remaining = TimeInterval(minutes * 60)
        resume()
    }

    /// Tapping toggles between running and paused, and does nothing at all when
    /// no duration has been set — a countdown from zero is not a feature.
    func tap() {
        guard remaining > 0 else { return }
        isRunning ? pause() : resume()
    }

    func reset() {
        pause()
        remaining = 0
    }

    private func resume() {
        guard remaining > 0 else { return }
        isRunning = true
        ticker?.invalidate()
        let created = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            // Timer honours the run loop it is added to, so this is the main
            // thread by construction. `assumeIsolated` says so rather than
            // deferring with a Task, and traps if that stops holding.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.remaining = max(0, self.remaining - 1)
                if self.remaining == 0 { self.pause() }
            }
        }
        // 10% tolerance so the system can coalesce this with other wake-ups. A
        // second-granularity countdown does not care when in the second it runs.
        created.tolerance = 0.1
        RunLoop.main.add(created, forMode: .common)
        ticker = created
    }

    private func pause() {
        isRunning = false
        ticker?.invalidate()
        ticker = nil
    }
}
