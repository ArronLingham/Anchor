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
import AVFoundation
import Combine
import Defaults
import EventKit
import KeyboardShortcuts
import LaunchAtLogin
import LottieUI
import Sparkle
import SwiftUI
import SwiftUIIntrospect
import UniformTypeIdentifiers

// Extracted from SettingsView.swift, originally created by
// Richard Kunkli on 07/08/2024. Behaviour unchanged.

struct Media: View {
    @ObservedObject private var displayManager = ExternalDisplayManager.shared
    @ObservedObject private var cameraManager = CameraMirrorManager.shared
    @Default(.enableCameraMirror) private var enableCameraMirror
    @Default(.enablePerAppAudio) private var enablePerAppAudio
    @Default(.perAppVolumeMode) private var perAppVolumeMode
    @Default(.showPerAppVolumeControl) private var showPerAppVolumeControl
    @Default(.cameraMirrorDeviceID) private var cameraMirrorDeviceID
    @Default(.pinnedInputDeviceUID) private var pinnedInputDeviceUID
    @Default(.lyricsOffsetSeconds) var lyricsOffsetSeconds
    @Default(.enableLyrics) var enableLyrics
    @Default(.lyricsVisibleLines) var lyricsVisibleLines
    @Default(.waitInterval) var waitInterval
    @Default(.mediaController) var mediaController
    @ObservedObject var coordinator = AnchorViewCoordinator.shared
    @Default(.hideNotchOption) var hideNotchOption
    @Default(.enableSneakPeek) private var enableSneakPeek
    @Default(.sneakPeekStyles) var sneakPeekStyles
    @Default(.enableMinimalisticUI) var enableMinimalisticUI
    @Default(.showShuffleAndRepeat) private var showShuffleAndRepeat
    @Default(.musicSkipBehavior) private var musicSkipBehavior
    @Default(.musicControlWindowEnabled) private var musicControlWindowEnabled
    @Default(.enableLockScreenMediaWidget) private var enableLockScreenMediaWidget
    @Default(.showSneakPeekOnTrackChange) private var showSneakPeekOnTrackChange
    @Default(.lockScreenGlassStyle) private var lockScreenGlassStyle
    @Default(.lockScreenGlassCustomizationMode) private var lockScreenGlassCustomizationMode
    @Default(.lockScreenMusicAlbumParallaxEnabled) private var lockScreenMusicAlbumParallaxEnabled
    @Default(.lockScreenMusicFullscreenArtworkEnabled) private var lockScreenMusicFullscreenArtworkEnabled
    @Default(.showStandardMediaControls) private var showStandardMediaControls
    @Default(.autoHideInactiveNotchMediaPlayer) private var autoHideInactiveNotchMediaPlayer
    @Default(.visualizerBarCount) private var visualizerBarCount
    @Default(.enableWaveformScrubber) private var enableWaveformScrubber
    @Default(.colorExtractionMode) private var colorExtractionMode
    @Default(.parallaxEffectIntensity) private var parallaxEffectIntensity

    
    @ObservedObject private var musicManager = MusicManager.shared

    private var isAppleMusicActive: Bool {
        musicManager.bundleIdentifier == "com.apple.Music"
    }

    private func highlightID(_ title: String) -> String {
        SettingsTab.media.highlightID(for: title)
    }

    private var standardControlsSuppressed: Bool {
        !showStandardMediaControls && !enableMinimalisticUI
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enablePerAppAudio) {
                    Text("Per-app volume, mute and EQ")
                }
                .settingsHighlight(id: highlightID("Per-app mute"))

                if enablePerAppAudio {
                    Defaults.Toggle(key: .showPerAppVolumeControl) {
                        Text("Show the volume control")
                    }
                    .settingsHighlight(id: highlightID("Show the volume control"))
                    .settingsInfo("Turn this off to keep the equaliser, mute and output routing without the per-app volume stepper. Mute stays on the row \u{2014} hiding it too would leave a muted app with no way to unmute it.")

                    if showPerAppVolumeControl {
                        Picker("Volume control", selection: $perAppVolumeMode) {
                            ForEach(PerAppVolumeMode.allCases) { mode in
                                Text(mode.localizedName).tag(mode)
                            }
                        }
                        .settingsHighlight(id: highlightID("Volume control"))
                        .settingsInfo(perAppVolumeMode.detail)
                    }

                    PerAppAudioList()
                }
            } header: {
                Text("Per-app audio")
            } footer: {
                Text("Mute or set the volume of one app without touching system volume. Both are released when you undo them, when the app quits, and if Anchor stops running — macOS owns the tap, so nothing stays muted or quietened after Anchor is gone.\n\nA volume other than 100% is not a property write: CoreAudio has no per-process volume, so Anchor taps the app, mutes it at the device, and re-renders its audio at the level you chose through a private aggregate device. That path only runs while a slider is away from 100%, and if any part of it fails to start the app is left at normal volume rather than muted with nothing replacing it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Hold this microphone as the default", selection: $pinnedInputDeviceUID) {
                    Text("Let macOS choose").tag("")
                    ForEach(AudioDeviceToolsManager.shared.inputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .settingsHighlight(id: highlightID("Pin microphone"))
                .onAppear { AudioDeviceToolsManager.shared.refreshInputDevices() }

                Defaults.Toggle(key: .enableAudioDeviceHUD) {
                    Text("Show the mic HUD when muting every microphone")
                }
                .settingsHighlight(id: highlightID("Audio device HUD"))
            } header: {
                Text("Audio devices")
            } footer: {
                Text("macOS reassigns the default microphone whenever anything with one appears \u{2014} a monitor, AirPods, a headset. Pinning holds your choice instead. It gives up if the pinned device is unplugged, so macOS takes over again rather than leaving you with no microphone.\n\nShortcuts for cycling the output device and muting every microphone at once are in the Shortcuts pane.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .enableCameraMirror) {
                    Text("Camera mirror")
                }
                .settingsHighlight(id: highlightID("Camera mirror"))

                if enableCameraMirror {
                    Picker("Camera", selection: $cameraMirrorDeviceID) {
                        Text("First available").tag("")
                        ForEach(cameraManager.availableCameras, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID)
                        }
                    }
                    .onAppear { cameraManager.refreshDevices() }

                    Defaults.Toggle(key: .cameraMirrorFlipped) {
                        Text("Flip horizontally")
                    }
                    .settingsInfo("On, the preview behaves like a mirror \u{2014} raising your right hand raises the right hand of the image. Off shows the raw camera feed, which is what other people see.")
                }
            } header: {
                Text("Camera")
            } footer: {
                Text("Adds a Mirror tab to the open notch showing a live camera preview. **Nothing is recorded, saved or sent anywhere** \u{2014} the capture session has no file, photo or data output at all, which a test enforces rather than a promise.\n\nThe camera runs only while the Mirror tab is on screen, so the green indicator light is lit for exactly as long as you can see the preview, and never otherwise.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if !ExternalDisplayManager.isAvailable {
                    Text("This build of macOS does not expose the DDC interface.")
                        .foregroundStyle(.secondary)
                } else {
                    let externals = displayManager.displays.filter { !$0.isBuiltin }
                    if displayManager.isProbing {
                        Text("Asking displays\u{2026}").foregroundStyle(.secondary)
                    } else if externals.isEmpty {
                        HStack {
                            Text("No external display attached.").foregroundStyle(.secondary)
                            Spacer()
                            Button("Check") { Task { await displayManager.probe() } }
                                .settingsHighlight(id: highlightID("External display brightness"))
                        }
                    } else {
                        ForEach(externals) { display in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(display.name)
                                    Spacer()
                                    if display.supportsDDC == true {
                                        Text("DDC available").font(.caption).foregroundStyle(.secondary)
                                    } else if display.supportsDDC == false {
                                        Text("no DDC response").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                if display.supportsDDC == true, let value = display.currentFraction {
                                    Slider(value: Binding(
                                        get: { value },
                                        set: { displayManager.setBrightness($0, on: display) }),
                                           in: 0...1)
                                } else if display.supportsDDC == false {
                                    Text("This display did not answer. DDC/CI is often switched off in the monitor's own menu, and it rarely survives a hub or an adapter.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Re-check") { Task { await displayManager.probe() } }
                        }
                    }
                }
            } header: {
                Text("External display brightness")
            } footer: {
                Text("macOS's own brightness API covers the built-in screen only \u{2014} it returns an error for external displays, which is why this uses DDC/CI over I2C instead, the same channel a monitor's own buttons use.\n\nNothing is sent until you move a slider, and a display that does not answer a read is never written to: without a working read there is no way to put the brightness back.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // Listing displays costs nothing — no I2C is sent — so it happens
            // on appear. Without it the pane said "No external display
            // attached" while one plainly was: the same false claim the
            // Homebrew row made before `brewAvailable` moved into init. The
            // DDC *probe* stays behind the button, because that writes to the
            // bus.
            .onAppear { displayManager.refresh() }

            Section {
                Picker("Music Source", selection: $mediaController) {
                    ForEach(availableMediaControllers) { controller in
                        Text(controller.localizedName).tag(controller)
                    }
                }
                .onChange(of: mediaController) { _, _ in
                    NotificationCenter.default.post(
                        name: Notification.Name.mediaControllerChanged,
                        object: nil
                    )
                }
                .settingsHighlight(id: highlightID("Music Source"))
            } header: {
                Text("Media Source")
            } footer: {
                if MusicManager.shared.isNowPlayingDeprecated {
                    HStack {
                        Text("YouTube Music requires this third-party app to be installed: ")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Link("https://github.com/th-ch/youtube-music", destination: URL(string: "https://github.com/th-ch/youtube-music")!)
                            .font(.caption)
                            .foregroundColor(.blue) // Ensures it's visibly a link
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "'Now Playing' was the only option on previous versions and works with all media apps."))
                        Text(String(localized: "Uses macOS Now Playing when the Amazon Music app is the active media source. Playback controls follow the system Now Playing target. Scrubbing the timeline may not work if the Amazon Music app does not support remote seek."))
                    }
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
            }

            if mediaController == .spotify {
                SpotifyAuthSettingsSection()
            }

            Section {
                Defaults.Toggle(key: .showStandardMediaControls) {
                    Text("Show media controls in Dynamic Island")
                }
                .disabled(enableMinimalisticUI)
                .settingsHighlight(id: highlightID("Show media controls in Dynamic Island"))

                Defaults.Toggle(key: .autoHideInactiveNotchMediaPlayer) {
                    Text("Auto-hide inactive notch media player")
                }
                .disabled(enableMinimalisticUI || !showStandardMediaControls)
                .settingsHighlight(id: highlightID("Auto-hide inactive notch media player"))

                if enableMinimalisticUI {
                    Text("Disable Minimalistic UI to configure the standard notch media controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if standardControlsSuppressed {
                    Text("Standard notch media controls are hidden. Re-enable the toggle above to restore them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !autoHideInactiveNotchMediaPlayer {
                    Text("When disabled, the notch music player stays visible with placeholder metadata even when playback is inactive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Dynamic Island Visibility")
            }
            Section {
                Defaults.Toggle(key: .showShuffleAndRepeat) {
                    HStack {
                        Text("Enable customizable controls")
                        customBadge(text: "Beta")
                    }
                }
                if showShuffleAndRepeat {
                    Defaults.Toggle(key: .showMediaOutputControl) {
                        Text("Show \"Change Media Output\" control")
                    }
                    .settingsHighlight(id: highlightID("Show Change Media Output control"))
                    .settingsInfo("Adds the AirPlay/route picker button back to the customizable controls palette.")
                    MusicSlotConfigurationView()
                } else {
                    Text("Turn on customizable controls to rearrange media buttons.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            } header: {
                Text("Media controls")
            }

            Section(header: Text("Lock Screen Media")) {
                Defaults.Toggle(key: .lockScreenMusicAlbumParallaxEnabled) {
                    Text("Enable album art parallax")
                }
                .settingsHighlight(id: highlightID("Enable album art parallax"))
                Text("Applies the notch-style parallax effect to the lock screen media widget album art.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if musicControlWindowEnabled {
                Section {
                    Picker("Skip buttons", selection: $musicSkipBehavior) {
                        ForEach(MusicSkipBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .pickerStyle(.segmented)
                    .settingsHighlight(id: highlightID("Skip buttons"))

                    Text(musicSkipBehavior.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Floating window panel skip behaviour")
                }
            }
            Section {
                Toggle(
                    "Enable music live activity",
                    isOn: $coordinator.musicLiveActivityEnabled.animation()
                )
                .disabled(standardControlsSuppressed)
                .help(standardControlsSuppressed ? "Standard notch media controls are hidden while this toggle is off." : "")
                Defaults.Toggle(key: .musicControlWindowEnabled) {
                    Text("Show floating media controls")
                }
                .disabled(!coordinator.musicLiveActivityEnabled || standardControlsSuppressed)
                .settingsInfo("Displays play/pause and skip buttons beside the notch while music is active. Disabled by default.")
                Toggle("Enable sneak peek", isOn: $enableSneakPeek)
                Toggle("Show sneak peek on playback changes", isOn: $showSneakPeekOnTrackChange)
                    .disabled(!enableSneakPeek)
                Defaults.Toggle(key: .enableLyrics) {
                    Text("Enable lyrics")
                }
                .settingsHighlight(id: highlightID("Enable lyrics"))
                Defaults.Toggle(key: .lyricsTranslationEnabled) {
                    Text("Translate lyrics")
                }
                .disabled(!enableLyrics)
                .settingsHighlight(id: highlightID("Translate lyrics"))
                .settingsInfo("Shows a translation beneath the current line, into your Mac's language. Runs on device through Apple's Translation framework — no key, no network, and nothing about what you are listening to leaves the machine. macOS may ask to download a language model the first time.")

                LabeledContent("Lines shown") {
                    Picker("", selection: $lyricsVisibleLines) {
                        Text("As many as fit").tag(0)
                        ForEach([1, 2, 3, 4, 5, 6, 8], id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(!enableLyrics)
                .settingsHighlight(id: highlightID("Lines shown"))
                .settingsInfo("How many lines the notch shows at once. A fixed count is still clamped to what fits, so asking for eight in a space that holds four does not crop them.")

                Slider(value: $lyricsOffsetSeconds, in: -1...1, step: 0.05) {
                    HStack {
                        Text("Lyrics timing")
                        Spacer()
                        Text(lyricsOffsetSeconds == 0
                             ? "on the beat"
                             : String(format: "%+.2fs %@", lyricsOffsetSeconds,
                                      lyricsOffsetSeconds > 0 ? "early" : "late"))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .disabled(!enableLyrics)
                .settingsHighlight(id: highlightID("Lyrics timing"))
                .settingsInfo("Nudge lyrics earlier or later. Players report the position their decoder has reached, which runs ahead of what you hear, and that report arrives with its own lag — how much depends on the app and the output device.")
                Defaults.Toggle(key: .showLiveCanvasInDynamicIsland) {
                    Text("Show live canvas in Dynamic Island")
                }
                .settingsHighlight(id: highlightID("Show live canvas in Dynamic Island"))
                .settingsInfo("Replaces the artwork tile with the live canvas when the current app provides one, and reuses that moving canvas for the surrounding lighting effect.")
                
                //Parallax Effect Intensity to control how much parallax is wanted
                Slider(value: $parallaxEffectIntensity, in: 0...12, step: 1.0) {
                    HStack {
                        Text("Parallax Effect Intensity")
                        Spacer()
                        Text("\(parallaxEffectIntensity, specifier: "%0.1f")")
                            .foregroundStyle(.secondary)
                    }
                }
                .settingsHighlight(id: highlightID("Enable album art parallax effect"))
                
                Picker("Sneak Peek Style", selection: $sneakPeekStyles){
                    ForEach(SneakPeekStyle.allCases) { style in
                        Text(style.localizedName).tag(style)
                    }
                }
                .disabled(!enableSneakPeek)
                .settingsHighlight(id: highlightID("Sneak Peek Style"))

                HStack {
                    Stepper(value: $waitInterval, in: 0...10, step: 1) {
                        HStack {
                            Text("Media inactivity timeout")
                            Spacer()
                            Text("\(Defaults[.waitInterval], specifier: "%.0f") seconds")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Defaults.Toggle(key: .showSongMetadataInClosedNotch) {
                    Text("Show song title and artist on non-notch displays")
                }
                .settingsHighlight(id: highlightID("Show song title and artist in closed notch"))
            } header: {
                Text("Media playback live activity")
            }

            Section {
                Defaults.Toggle(key: .enableRealTimeWaveform) {
                    HStack {
                        Text("Enable real-time waveform")
                        customBadge(text: "Beta")
                    }
                }
                .settingsHighlight(id: highlightID("Enable real-time waveform"))
                
                Picker("Visualizer candles", selection: $visualizerBarCount) {
                    Text("4").tag(4)
                    Text("5").tag(5)
                    Text("6").tag(6)
                }
                
                Picker("Color extraction", selection: $colorExtractionMode) {
                    Text("Legacy").tag(ColorExtractionMode.legacy)
                    Text("Vibrant").tag(ColorExtractionMode.vibrant)
                }
                
                Toggle("Scrubbable real-time waveform", isOn: $enableWaveformScrubber)
            } header: {
                Text("Music Visualizer")
            } footer: {
                Text("When enabled, the music visualizer displays real-time audio spectrum data synced to your music. Requires macOS 14.2+ and uses minimal CPU/GPU resources via the Accelerate framework.")
            }

            Section {
                Defaults.Toggle(key: .enableLockScreenMediaWidget) {
                    Text("Show lock screen media panel")
                }
                Defaults.Toggle(key: .lockScreenShowAppIcon) {
                    Text("Show media app icon")
                }
                .disabled(!enableLockScreenMediaWidget)
                if isAppleMusicActive {
                    Defaults.Toggle(key: .lockScreenMusicMergedAirPlayOutput) {
                        Text("Show merged AirPlay and output devices")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                    .settingsHighlight(id: highlightID("Show merged AirPlay and output devices"))
                }
                Defaults.Toggle(key: .lockScreenPanelShowsBorder) {
                    Text("Show panel border")
                }
                .disabled(!enableLockScreenMediaWidget)
                if lockScreenGlassCustomizationMode == .customLiquid {
                    Defaults.Toggle(key: .lockScreenMusicUsesEnhancedLiquidBorder) {
                        Text("Use enhanced liquid border")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                }
                if lockScreenGlassCustomizationMode == .customLiquid {
                    customLiquidBlurRow
                        .opacity(enableLockScreenMediaWidget ? 1 : 0.5)
                        .settingsHighlight(id: highlightID("Enable media panel blur"))
                } else if lockScreenGlassStyle == .frosted {
                    Defaults.Toggle(key: .lockScreenPanelUsesBlur) {
                        Text("Enable media panel blur")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                    .settingsHighlight(id: highlightID("Enable media panel blur"))
                } else {
                    unavailableBlurRow
                        .opacity(enableLockScreenMediaWidget ? 1 : 0.5)
                        .settingsHighlight(id: highlightID("Enable media panel blur"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Defaults.Toggle(key: .lockScreenMusicFullscreenArtworkEnabled) {
                        Text("Fullscreen artwork on right-click")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                    .settingsHighlight(id: highlightID("Fullscreen artwork on right-click"))
                    Defaults.Toggle(key: .lockScreenUseArtworkLayoutOverFullscreenCanvas) {
                        Text("Use album art layout over fullscreen canvas")
                    }
                    .disabled(!enableLockScreenMediaWidget || !lockScreenMusicFullscreenArtworkEnabled)
                    .settingsHighlight(id: highlightID("Use album art layout over fullscreen canvas"))
                    Defaults.Toggle(key: .lockScreenKeepAlbumArtVisibleDuringFullscreenArtwork) {
                        Text("Keep album art visible during fullscreen artwork")
                    }
                    .disabled(!enableLockScreenMediaWidget || !lockScreenMusicFullscreenArtworkEnabled)
                    .settingsHighlight(id: highlightID("Keep album art visible during fullscreen artwork"))
                    Text("Right-click the album art on the lock screen to set it as the wallpaper. Right-click again or click the background to restore the original wallpaper. If a canvas is available, Anchor can also keep the same album art + player layout on top of the live canvas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Lock Screen Integration")
            } footer: {
                Text("These controls mirror the Lock Screen tab so you can tune the media overlay while focusing on playback settings.")
            }
            .disabled(!showStandardMediaControls)
            .opacity(showStandardMediaControls ? 1 : 0.5)

            Picker(selection: $hideNotchOption, label:
                    HStack {
                Text("Hide DynamicIsland Options")
                customBadge(text: "Beta")
            }) {
                Text("Always hide in fullscreen").tag(HideNotchOption.always)
                Text("Hide only when NowPlaying app is in fullscreen").tag(HideNotchOption.nowPlayingOnly)
                Text("Never hide").tag(HideNotchOption.never)
            }
            .onChange(of: hideNotchOption) {
                Defaults[.enableFullscreenMediaDetection] = hideNotchOption != .never
            }
        }
        .navigationTitle("Media")
    }

    // Only show controller options that are available on this macOS version
    private var availableMediaControllers: [MediaControllerType] {
        if MusicManager.shared.isNowPlayingDeprecated {
            return MediaControllerType.allCases.filter { $0 != .nowPlaying }
        } else {
            return MediaControllerType.allCases
        }
    }

    private var unavailableBlurRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Enable media panel blur")
                .foregroundStyle(.secondary)
            Text("Only applies when Material is set to Frosted Glass.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var customLiquidBlurRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Enable media panel blur")
                .foregroundStyle(.secondary)
            Text("Custom liquid glass already renders with Apple's liquid material, so this option is managed automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
