import AppKit
import Defaults
import EventKit
import SwiftUI

struct SettingsIntegrations: View {
    @ObservedObject private var lunar = LunarManager.shared
    @ObservedObject private var spotify = SpotifyAuthManager.shared
    @ObservedObject private var calendar = CalendarManager.shared
    @ObservedObject private var reminders = LauncherAppleReminders.shared
    @Default(.enableThirdPartyDDCIntegration) private var ddcEnabled
    @Default(.thirdPartyDDCProvider) private var provider
    @State private var showingSpotify = false
    @State private var reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
    @State private var calendarStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var repairing = Set<String>()

    var body: some View {
        Form {
            Section("Lunar") {
                status(lunar.isConnected && ddcEnabled && provider == .lunar,
                       ddcEnabled && provider == .lunar ? lunar.connectionMessage : "Lunar integration is off")
                Text("Anchor starts Lunar when a monitor connects and refreshes monitor controls after reconnecting or waking.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reconnect Lunar") {
                    provider = .lunar
                    ddcEnabled = true
                    lunar.repairConnection()
                }
            }
            Section("Spotify") {
                status(spotify.isAuthenticated, spotify.sessionStatusText)
                if let error = spotify.authErrorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Check connection") { Task { await spotify.validateSession() } }
                        .disabled(spotify.isAuthorizing)
                    Button("Sign in again") { showingSpotify = true }
                }
            }
            Section("Calendar") {
                status(calendarStatus == .fullAccess, accessText(calendarStatus))
                Button("Repair Calendar access") {
                    repair("calendar") {
                        if calendarStatus == .denied || calendarStatus == .restricted { openPrivacy("Calendars") }
                        else {
                            await calendar.checkCalendarAuthorization()
                            await calendar.updateLauncherEvents(force: true)
                        }
                        refreshStatuses()
                    }
                }.disabled(repairing.contains("calendar"))
            }
            Section("Reminders") {
                status(reminderStatus == .fullAccess, accessText(reminderStatus))
                if let error = reminders.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                Button("Repair Reminders access") {
                    repair("reminders") {
                        if reminderStatus == .denied || reminderStatus == .restricted { openPrivacy("Reminders") }
                        else { await reminders.refresh(force: true) }
                        refreshStatuses()
                    }
                }.disabled(repairing.contains("reminders"))
            }
        }
        .formStyle(AnchorFormStyle())
        .sheet(isPresented: $showingSpotify) { SpotifyLoginSheet { cookie in
            Defaults[.spotifySPDCCookie] = SpotifyAuthManager.sanitizeCookie(cookie)
            Task { await spotify.validateSession() }
        } }
        .onAppear { refreshStatuses(); lunar.refreshDetectionStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshStatuses() }
    }

    private func status(_ connected: Bool, _ text: String) -> some View {
        Label(text, systemImage: connected ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(connected ? Color.green : Color.orange)
    }
    private func accessText(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: return "Connected"
        case .denied, .restricted: return "Access disabled in System Settings"
        case .writeOnly: return "Full access needed"
        default: return "Access not yet requested"
        }
    }
    private func refreshStatuses() {
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
        reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
    }
    private func repair(_ id: String, action: @escaping @MainActor () async -> Void) {
        repairing.insert(id)
        Task { await action(); repairing.remove(id) }
    }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
