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

@preconcurrency import Foundation
import AppKit
import Combine
import Defaults
import Network

// MARK: - Lunar Display Data Model

/// Matches the JSON structure streamed by Lunar's socket listener.
// MARK: - Lunar Control Category


// MARK: - Lunar Manager

/// Manages integration with the Lunar app (fyi.lunar.Lunar).
///
/// Responsibilities:
/// - Detect whether Lunar is installed and running
/// - Observe app launch / termination to connect / disconnect automatically
/// - Connect to Lunar's TCP socket on localhost:23803 and listen for DDC changes
/// - Route brightness / contrast / volume events to Atoll's HUD pipeline
@MainActor
final class LunarManager: ObservableObject {
    static let shared = LunarManager()

    /// Bundle identifier of the Lunar app.
    nonisolated static let bundleID = "fyi.lunar.Lunar"

    /// UserDefaults suite used by Lunar to store its API key.
    // `nonisolated` because `retrieveAPIKey()` and `writeLunarDefault(hideOSD:)`
    // are nonisolated so they can run from `deinit`. Both are immutable
    // strings, so there is nothing to isolate. Without this it is a warning
    // today and a build error under the Swift 6 language mode.
    nonisolated private static let lunarDomain = "fyi.lunar.Lunar"
    nonisolated private static let apiKeyKey = "apiKey"

    // MARK: Published state

    /// Whether Lunar is currently detected (installed) on this machine.
    @Published private(set) var isDetected: Bool = false

    /// Whether Lunar is currently running.
    @Published private(set) var isRunning: Bool = false

    /// Whether the TCP socket connection to Lunar is active.
    @Published private(set) var isConnected: Bool = false

    // MARK: Private

    private var connection: NWConnection?
    private var displayRefreshConnection: NWConnection?
    private var displayRefreshTimeout: Task<Void, Never>?
    private var displayRecoveryTask: Task<Void, Never>?
    private var displayRecoveryState = LunarDisplayRecoveryState()
    private var launchingLunar = false
    private var displayRefreshPending = false
    private var workspaceLaunchObserver: NSObjectProtocol?
    private var workspaceTermObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private weak var coordinator: AnchorViewCoordinator?

    /// Reconnection back-off state.
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts: Int = 0
    private var connectionTimeout: Task<Void, Never>?
    private var messageStream = LunarMessageStream()
    @Published private(set) var connectionMessage = "Not connected"
    private static let baseReconnectDelay: UInt64 = 2_000_000_000 // 2 seconds

    private var isLunarIntegrationEnabled: Bool {
        Defaults[.enableThirdPartyDDCIntegration] && Defaults[.thirdPartyDDCProvider] == .lunar
    }

    private var isExternalVolumeListenerEnabled: Bool {
        isLunarIntegrationEnabled && Defaults[.enableExternalVolumeControlListener]
    }

    private init() {
        isDetected = Self.checkInstallation()
        isRunning = Self.checkRunning()
        setupWorkspaceObservers()
        setupSettingsObserver()
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.scheduleDisplayRecovery(force: true) }
                }
                .store(in: &cancellables)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.scheduleDisplayRecovery() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Configure with the view coordinator for HUD dispatch.
    func configure(coordinator: AnchorViewCoordinator) {
        self.coordinator = coordinator
        refreshConnectionState()
    }

    /// Called when Atoll is about to quit so Lunar's native OSD is restored.
    func appWillTerminate() {
        setLunarHideOSD(false)
    }

    /// Refresh detection status (e.g. after manual check from Settings).
    func refreshDetectionStatus() {
        let wasRunning = isRunning
        isDetected = Self.checkInstallation()
        isRunning = Self.checkRunning()
        if wasRunning != isRunning {
            NSLog("🌙 Lunar running state changed: running=\(isRunning)")
        }
        refreshConnectionState()
    }

    // MARK: - Detection

    /// Check if Lunar is installed by looking for its bundle ID.
    nonisolated static func checkInstallation() -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
            return true
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.fileExists(atPath: url.path)
        }
        return false
    }

    /// Check if Lunar is currently running.
    nonisolated static func checkRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID })
    }

    // MARK: - Socket Connection

    private func connectToLunar() {
        guard isLunarIntegrationEnabled, isRunning, connection == nil else { return }
        guard let apiKey = Self.retrieveAPIKey() else {
            connectionMessage = "Waiting for Lunar — using its HUD"
            setLunarHideOSD(false)
            scheduleReconnect()
            return
        }

        connectionMessage = "Connecting…"
        let host = NWEndpoint.Host("127.0.0.1")
        let port = NWEndpoint.Port(23803)
        let conn = NWConnection(host: host, port: port, using: .tcp)

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                self.handleConnectionState(state, apiKey: apiKey)
            }
        }

        connection = conn
        messageStream = LunarMessageStream()
        connectionTimeout?.cancel()
        connectionTimeout = Task { @MainActor [weak self, weak conn] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, let conn, self.connection === conn,
                  !self.isConnected else { return }
            self.connectionLost()
        }
        conn.start(queue: DispatchQueue.global(qos: .utility))
        NSLog("🌙 Lunar: connecting to socket on \(host):\(port)…")
    }

    private func disconnect() {
        connectionTimeout?.cancel()
        displayRecoveryTask?.cancel()
        displayRecoveryTask = nil
        cancelDisplayRefresh()
        displayRefreshPending = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0

        if let conn = connection {
            conn.stateUpdateHandler = nil
            conn.cancel()
            connection = nil
        }
        isConnected = false
        connectionMessage = "Not connected"
        setLunarHideOSD(false)
        NSLog("⏹ Lunar: socket disconnected")
    }

    private func handleConnectionState(_ state: NWConnection.State, apiKey: String) {
        switch state {
        case .ready:
            connectionTimeout?.cancel()
            isConnected = true
            connectionMessage = "Connected"
            setLunarHideOSD(true)
            reconnectAttempts = 0
            NSLog("🌙 Lunar: connected to socket")
            if displayRefreshPending {
                refreshLunarDisplays(apiKey: apiKey)
            } else {
                sendListenCommand(apiKey: apiKey)
                receiveMessages()
            }

        case .failed(let error):
            NSLog("🌙 Lunar: connection failed — \(error.localizedDescription)")
            connectionLost()

        case .cancelled:
            isConnected = false

        case .waiting(let error):
            NSLog("🌙 Lunar: connection waiting — \(error.localizedDescription)")

        default:
            break
        }
    }

    /// Send Lunar's listen command with the API key.
    private func sendListenCommand(apiKey: String) {
        guard let conn = connection else { return }

        let separator = String(UnicodeScalar(0x01))
        let message = [apiKey, "listen", "--json", "--only-user-adjustments"]
            .joined(separator: separator)

        guard let data = message.data(using: .utf8) else {
            NSLog("⚠️ Lunar: failed to encode listen command")
            return
        }

        conn.send(content: data, completion: .contentProcessed { error in
            if let error {
                NSLog("⚠️ Lunar: failed to send listen command — \(error.localizedDescription)")
            } else {
                NSLog("🌙 Lunar: listen command sent")
            }
        })
    }

    /// Cancel stale callbacks before scheduling a fresh authenticated stream.
    private func connectionLost() {
        connectionTimeout?.cancel()
        cancelDisplayRefresh()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        isConnected = false
        messageStream = LunarMessageStream()
        connectionMessage = "Reconnecting — Lunar HUD available"
        setLunarHideOSD(false)
        scheduleReconnect()
    }

    /// A socket reconnect alone cannot repair Lunar's cached I/O routes.
    func repairConnection() {
        disconnect()
        recoverDisplays()
    }

    private static func displaySnapshot() -> Set<String> {
        Set(NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  CGDisplayIsBuiltin(id) == 0 else { return nil }
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map {
                CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
            } ?? "unknown"
            return "\(id):\(uuid)"
        })
    }

    /// No polling: react only to a changed physical display set or a wake.
    /// Ignore resolution/EDR notification storms and let hot-plug settle first.
    private func scheduleDisplayRecovery(force: Bool = false) {
        guard displayRecoveryState.observe(Self.displaySnapshot(), force: force) else { return }
        displayRecoveryTask?.cancel()
        guard isLunarIntegrationEnabled, !Self.displaySnapshot().isEmpty else { return }
        displayRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.isLunarIntegrationEnabled,
                  !Self.displaySnapshot().isEmpty else { return }
            self.displayRecoveryTask = nil
            self.disconnect()
            self.recoverDisplays()
        }
    }

    private func recoverDisplays() {
        guard isLunarIntegrationEnabled else { return }
        isDetected = Self.checkInstallation()
        isRunning = Self.checkRunning()
        displayRefreshPending = !Self.displaySnapshot().isEmpty
        if isRunning {
            connectToLunar()
        } else if isDetected, !launchingLunar,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) {
            launchingLunar = true
            connectionMessage = "Starting Lunar…"
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.launchingLunar = false
                    guard self.isLunarIntegrationEnabled else { return }
                    self.isRunning = Self.checkRunning()
                    if error != nil || !self.isRunning {
                        self.connectionMessage = "Could not start Lunar — open it to restore monitor control"
                    } else {
                        self.refreshConnectionState()
                    }
                }
            }
        } else {
            connectionMessage = isDetected ? "Lunar is not running" : "Lunar is not installed"
        }
    }

    private func cancelDisplayRefresh() {
        displayRefreshTimeout?.cancel()
        displayRefreshTimeout = nil
        displayRefreshConnection?.stateUpdateHandler = nil
        displayRefreshConnection?.cancel()
        displayRefreshConnection = nil
    }

    /// Lunar's supported refresh-displays command re-enumerates monitors and
    /// restarts DDC detection and its media-key tap. Use a separate bounded
    /// authenticated request; never interleave commands with a listen stream.
    private func refreshLunarDisplays(apiKey: String) {
        guard displayRefreshConnection == nil else { return }
        let request = NWConnection(host: "127.0.0.1", port: 23803, using: .tcp)
        displayRefreshConnection = request
        connectionMessage = "Refreshing monitor controls…"
        displayRefreshTimeout = Task { @MainActor [weak self, weak request] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, let request,
                  self.displayRefreshConnection === request else { return }
            self.finishDisplayRefresh(succeeded: false)
        }
        request.stateUpdateHandler = { [weak self, weak request] state in
            Task { @MainActor in
                guard let self, let request, self.displayRefreshConnection === request else { return }
                switch state {
                case .ready:
                    let command = Data([apiKey, "refresh-displays"].joined(separator: "\u{01}").utf8)
                    request.send(content: command, completion: .contentProcessed { [weak self, weak request] error in
                        guard error != nil else { return }
                        Task { @MainActor in
                            guard let self, let request, self.displayRefreshConnection === request else { return }
                            self.finishDisplayRefresh(succeeded: false)
                        }
                    })
                    self.receiveDisplayRefreshReply(from: request, buffer: Data())
                case .failed:
                    self.finishDisplayRefresh(succeeded: false)
                default: break
                }
            }
        }
        request.start(queue: .global(qos: .utility))
    }

    private func receiveDisplayRefreshReply(from request: NWConnection, buffer: Data) {
        request.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak request] data, _, complete, error in
            Task { @MainActor in
                guard let self, let request, self.displayRefreshConnection === request else { return }
                var reply = buffer
                if let data { reply.append(data) }
                if reply.contains(10) || complete || error != nil || reply.count > 4096 {
                    // A successful refresh returns a blank line. Treat any
                    // auth, command or status error as a failed repair.
                    self.finishDisplayRefresh(succeeded: error == nil && LunarDisplayRecoveryState.refreshSucceeded(reply))
                } else {
                    self.receiveDisplayRefreshReply(from: request, buffer: reply)
                }
            }
        }
    }

    private func finishDisplayRefresh(succeeded: Bool) {
        cancelDisplayRefresh()
        displayRefreshPending = false
        guard connection != nil else { return }
        if !succeeded {
            connectionMessage = "Connected — monitor refresh failed; retry Reconnect Lunar"
        } else {
            connectionMessage = "Connected"
        }
        // Rebind after Lunar replaces its display objects, even if the CG ID
        // was reused. Never advertise a successful hardware write here.
        if let apiKey = Self.retrieveAPIKey() {
            sendListenCommand(apiKey: apiKey)
            receiveMessages()
        }
    }

    private func receiveMessages() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak conn] data, _, complete, error in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                if let data, !data.isEmpty { self.handleReceivedData(data) }
                if complete || error != nil { self.connectionLost() }
                else { self.receiveMessages() }
            }
        }
    }

    private func handleReceivedData(_ data: Data) {
        guard isLunarIntegrationEnabled, isRunning else { return }
        do {
            for payload in try messageStream.append(data) { routeToHUD(payload) }
        } catch { connectionLost() }
    }

    // MARK: - HUD Routing

    private func routeToHUD(_ data: LunarDisplayData) {
        let targetScreen = resolveScreen(for: data.display)
        let isExternal = isExternalDisplay(data.display, resolvedScreen: targetScreen)
        let hasVolumeData = data.volume != nil || data.mute != nil
        let externalVolumeListenerEnabled = isExternalVolumeListenerEnabled
        let resolvedScreenText = targetScreen?.localizedName ?? "nil"
        let brightnessText = data.brightness.map { String($0) } ?? "nil"
        let contrastText = data.contrast.map { String($0) } ?? "nil"
        let volumeText = data.volume.map { String($0) } ?? "nil"
        let muteText = data.mute.map { String($0) } ?? "nil"

        NSLog(
            "🌙 Lunar routed payload: display=\(data.display) resolvedScreen=\(resolvedScreenText) isExternal=\(isExternal) brightness=\(brightnessText) contrast=\(contrastText) volume=\(volumeText) mute=\(muteText) hasVolumeData=\(hasVolumeData) externalVolumeListener=\(externalVolumeListenerEnabled)"
        )

        // Nits-only events are informational (no user-facing HUD needed).
        let hasActionableChange = data.brightness != nil || data.contrast != nil || data.volume != nil || data.mute != nil
        guard hasActionableChange else { return }

        // Brightness — values arrive in 0…1 range from Lunar
        if let brightness = data.brightness {
            let value = CGFloat(brightness)
            let icon = isExternal ? "display" : ""
            dispatchBrightnessHUD(value: value, icon: icon, onScreen: targetScreen)
        }

        // Contrast — show as brightness-style HUD with a contrast icon
        if let contrast = data.contrast {
            let value = CGFloat(contrast)
            dispatchBrightnessHUD(value: value, icon: "circle.righthalf.filled", onScreen: targetScreen)
        }

        // Volume
        if externalVolumeListenerEnabled {
            if let volume = data.volume {
                let value = CGFloat(volume)
                let isMuted = data.mute ?? false
                dispatchVolumeHUD(value: value, isMuted: isMuted, onScreen: targetScreen)
            } else if let mute = data.mute {
                // Mute toggle without a volume value
                dispatchVolumeHUD(value: mute ? 0 : 1, isMuted: mute, onScreen: targetScreen)
            }
        } else if hasVolumeData {
            NSLog("🌙 Lunar volume payload ignored because external volume listener is disabled")
        }
    }

    // MARK: - HUD Dispatch (mirrors BetterDisplayManager / SystemChangesObserver logic)

    private func dispatchVolumeHUD(value: CGFloat, isMuted: Bool, onScreen targetScreen: NSScreen? = nil) {
        if HUDSuppressionCoordinator.shared.shouldSuppressVolumeHUD { return }

        if Defaults[.enableCircularHUD] {
            CircularHUDWindowManager.shared.show(type: .volume, value: value, onScreen: targetScreen)
            return
        }
        if Defaults[.enableVerticalHUD] {
            VerticalHUDWindowManager.shared.show(type: .volume, value: value, icon: "", onScreen: targetScreen)
            return
        }
        if Defaults[.enableCustomOSD] && Defaults[.enableOSDVolume] {
            CustomOSDWindowManager.shared.showVolume(value: value, onScreen: targetScreen)
        }
        if Defaults[.enableSystemHUD] && !Defaults[.enableCustomOSD] && !Defaults[.enableVerticalHUD] && !Defaults[.enableCircularHUD] {
            coordinator?.toggleSneakPeek(
                status: true,
                type: .volume,
                value: value,
                icon: "",
                onScreen: targetScreen
            )
        }
    }

    private func dispatchBrightnessHUD(value: CGFloat, icon: String = "", onScreen targetScreen: NSScreen? = nil) {
        if Defaults[.enableCircularHUD] {
            CircularHUDWindowManager.shared.show(type: .brightness, value: value, icon: icon, onScreen: targetScreen)
            return
        }
        if Defaults[.enableVerticalHUD] {
            VerticalHUDWindowManager.shared.show(type: .brightness, value: value, icon: icon, onScreen: targetScreen)
            return
        }
        if Defaults[.enableCustomOSD] && Defaults[.enableOSDBrightness] {
            CustomOSDWindowManager.shared.showBrightness(value: value, icon: icon, onScreen: targetScreen)
        }
        if Defaults[.enableSystemHUD] && !Defaults[.enableCustomOSD] && !Defaults[.enableVerticalHUD] && !Defaults[.enableCircularHUD] {
            coordinator?.toggleSneakPeek(
                status: true,
                type: .brightness,
                value: value,
                icon: icon,
                onScreen: targetScreen
            )
        }
    }

    // MARK: - Helpers

    /// Retrieve the Lunar API key from its UserDefaults suite.
    nonisolated private static func retrieveAPIKey() -> String? {
        UserDefaults(suiteName: lunarDomain)?.string(forKey: apiKeyKey)
    }

    /// Resolve a Lunar display ID (CGDirectDisplayID) to the matching NSScreen.
    private func resolveScreen(for displayID: Int) -> NSScreen? {
        if let directDisplayID = UInt32(exactly: displayID),
           let matchedScreen = NSScreen.screens.first(where: { screenNumber(for: $0) == directDisplayID }) {
            return matchedScreen
        }

        // Fallback for integrations that send 1-based display indexes (e.g. 1, 2)
        if displayID > 0 {
            let index = displayID - 1
            if NSScreen.screens.indices.contains(index) {
                let fallback = NSScreen.screens[index]
                NSLog("🌙 Lunar: display=\(displayID) resolved via index fallback to '\(fallback.localizedName)'")
                return fallback
            }
        }

        NSLog("🌙 Lunar: unable to resolve display=\(displayID), HUD will show on all screens")
        return nil
    }

    /// Whether the given displayID refers to an external (non-built-in) display.
    private func isExternalDisplay(_ displayID: Int, resolvedScreen: NSScreen?) -> Bool {
        if let resolvedScreen,
           let resolvedDisplayID = screenNumber(for: resolvedScreen) {
            return CGDisplayIsBuiltin(resolvedDisplayID) == 0
        }
        if let displayIDValue = UInt32(exactly: displayID) {
            return CGDisplayIsBuiltin(displayIDValue) == 0
        }
        return false
    }

    private func screenNumber(for screen: NSScreen) -> UInt32? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return num.uint32Value
    }

    private func logDecodedPayload(_ data: LunarDisplayData, source: String) {
        let hasVolumeData = data.volume != nil || data.mute != nil
        let brightnessText = data.brightness.map { String($0) } ?? "nil"
        let contrastText = data.contrast.map { String($0) } ?? "nil"
        let volumeText = data.volume.map { String($0) } ?? "nil"
        let muteText = data.mute.map { String($0) } ?? "nil"
        NSLog(
            "🌙 Lunar decoded payload (\(source)): display=\(data.display) brightness=\(brightnessText) contrast=\(contrastText) volume=\(volumeText) mute=\(muteText) hasVolumeData=\(hasVolumeData)"
        )
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        guard isLunarIntegrationEnabled, isRunning else { return }
        reconnectTask?.cancel()
        let attempt = reconnectAttempts
        reconnectAttempts = min(reconnectAttempts + 1, 30)

        let delay = Self.baseReconnectDelay * UInt64(1 << min(attempt, 4)) // exponential back-off, max 32s

        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, self.isRunning, self.isLunarIntegrationEnabled else { return }
            NSLog("🌙 Lunar: reconnect attempt \(attempt + 1)")
            self.connectToLunar()
        }
    }

    // MARK: - Workspace Observers (detect Lunar launch / quit)

    private func setupWorkspaceObservers() {
        let lunarBundleID = Self.bundleID

        workspaceLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == lunarBundleID
            else { return }
            Task { @MainActor in
                NSLog("🟢 Lunar launched (pid: \(app.processIdentifier))")
                self?.isDetected = true
                self?.isRunning = true
                self?.disconnect()
                self?.displayRefreshPending = !Self.displaySnapshot().isEmpty
                if self?.isLunarIntegrationEnabled == true {
                    // Give Lunar a moment to start its socket server
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self?.connectToLunar()
                }
            }
        }

        workspaceTermObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == lunarBundleID
            else { return }
            Task { @MainActor in
                NSLog("🔴 Lunar terminated (pid: \(app.processIdentifier))")
                self?.isRunning = false
                self?.disconnect()
            }
        }
    }

    // MARK: - Settings Observer

    private func refreshConnectionState() {
        if isLunarIntegrationEnabled {
            if !isRunning, !Self.displaySnapshot().isEmpty {
                recoverDisplays()
            } else {
                connectToLunar()
            }
            scheduleDisplayRecovery()
        } else {
            disconnect()
            displayRecoveryState = LunarDisplayRecoveryState()
        }
    }

    private func setupSettingsObserver() {
        Defaults.publisher(.enableThirdPartyDDCIntegration, options: [])
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshConnectionState()
                }
            }
            .store(in: &cancellables)

        Defaults.publisher(.thirdPartyDDCProvider, options: [])
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshConnectionState()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        // Restore Lunar's native OSD synchronously on teardown
        LunarManager.writeLunarDefault(hideOSD: false)
        connection?.cancel()
        displayRefreshConnection?.cancel()
        displayRefreshTimeout?.cancel()
        displayRecoveryTask?.cancel()
        reconnectTask?.cancel()
        if let workspaceLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceLaunchObserver)
        }
        if let workspaceTermObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceTermObserver)
        }
        cancellables.removeAll()
    }

    // MARK: - Lunar OSD Suppression

    /// Tell Lunar to hide (or show) its own native OSD by writing to its UserDefaults.
    private func setLunarHideOSD(_ hide: Bool) {
        Self.writeLunarDefault(hideOSD: hide)
    }

    /// Synchronous, nonisolated helper so it can also be called from `deinit`.
    nonisolated private static func writeLunarDefault(hideOSD hide: Bool) {
        guard let defaults = UserDefaults(suiteName: lunarDomain) else {
            NSLog("⚠️ Lunar: unable to open UserDefaults suite '\(lunarDomain)' to set hideOSD")
            return
        }
        defaults.set(hide, forKey: "hideOSD")
        NSLog("🌙 Lunar: hideOSD set to \(hide)")
    }
}
