import Foundation
import CoreGraphics

/// Coordinates are fractions of a display's usable area, independent of resolution.
struct WorkspaceRect: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1

    func frame(in bounds: CGRect) -> CGRect {
        let w = min(1, max(0.05, width.isFinite ? width : 1))
        let h = min(1, max(0.05, height.isFinite ? height : 1))
        return CGRect(x: bounds.minX + min(1 - w, max(0, x.isFinite ? x : 0)) * bounds.width,
                      y: bounds.minY + min(1 - h, max(0, y.isFinite ? y : 0)) * bounds.height,
                      width: bounds.width * w, height: bounds.height * h)
    }

    static func capture(_ frame: CGRect, in bounds: CGRect) -> Self {
        guard bounds.width > 0, bounds.height > 0 else { return Self() }
        return Self(x: (frame.minX - bounds.minX) / bounds.width,
                    y: (frame.minY - bounds.minY) / bounds.height,
                    width: frame.width / bounds.width, height: frame.height / bounds.height)
    }
}

struct WorkspaceApp: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var path: String
    var id: String { bundleID }
}

struct DesktopDock: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "New Dock"
    var enabled = true
    var vertical = true
    /// Empty uses the primary display; disconnected displays fall back to it.
    var displayID = ""
    var x = 0.02
    var y = 0.5
    var iconSize = 40.0
    var apps: [WorkspaceApp] = []
}

enum WorkspaceDisplayCondition: String, Codable, CaseIterable {
    case any, laptopOnly, externalConnected, specificDisplay
    var title: String {
        switch self {
        case .any: return "Any display setup"
        case .laptopOnly: return "No external display"
        case .externalConnected: return "External display connected"
        case .specificDisplay: return "Specific display connected"
        }
    }
}

enum WorkspacePowerCondition: String, Codable, CaseIterable {
    case any, battery, pluggedIn, charging
    var title: String {
        switch self {
        case .any: return "Any power source"
        case .battery: return "On battery"
        case .pluggedIn: return "Plugged in"
        case .charging: return "Battery charging"
        }
    }
}

struct WorkspaceEnvironment: Equatable {
    var externalDisplayIDs: Set<String>
    var onAC: Bool
    var charging: Bool
}

struct WorkspaceRule: Codable, Equatable {
    var enabled = false
    var display: WorkspaceDisplayCondition = .any
    var displayID = ""
    var power: WorkspacePowerCondition = .any

    func matches(_ environment: WorkspaceEnvironment) -> Bool {
        guard enabled else { return false }
        // An unconstrained rule is deliberately inert: it must describe an event context.
        guard display != .any || power != .any else { return false }
        let displayMatches: Bool
        switch display {
        case .any: displayMatches = true
        case .laptopOnly: displayMatches = environment.externalDisplayIDs.isEmpty
        case .externalConnected: displayMatches = !environment.externalDisplayIDs.isEmpty
        case .specificDisplay: displayMatches = !displayID.isEmpty && environment.externalDisplayIDs.contains(displayID)
        }
        let powerMatches: Bool
        switch power {
        case .any: powerMatches = true
        case .battery: powerMatches = !environment.onAC
        case .pluggedIn: powerMatches = environment.onAC
        case .charging: powerMatches = environment.onAC && environment.charging
        }
        return displayMatches && powerMatches
    }
}

struct WorkspaceWindow: Codable, Equatable, Identifiable {
    var id = UUID()
    var app: WorkspaceApp
    var title: String
    var ordinal: Int
    var displayID: String
    var rect: WorkspaceRect
}

struct WorkspaceMode: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "New Mode"
    var symbol = "rectangle.3.group"
    var apps: [WorkspaceApp] = []
    var quitApps: [WorkspaceApp] = []
    var windows: [WorkspaceWindow] = []
    var rule = WorkspaceRule()
    var volume: Double? = nil
    var brightness: Double? = nil
    /// nil preserves current docks; an empty array hides all docks.
    var visibleDockIDs: [UUID]? = nil
    /// A user-selected macOS Shortcut can extend the mode with other settings.
    var shortcutName = ""

    static var starters: [Self] {
        [Self(name: "Travel", symbol: "airplane", rule: WorkspaceRule(display: .laptopOnly, power: .battery)),
         Self(name: "Desktop", symbol: "desktopcomputer", rule: WorkspaceRule(display: .externalConnected))]
    }
}

struct DesktopWorkspaceConfiguration: Codable, Equatable {
    var version = 1
    var docks: [DesktopDock] = []
    var modes = WorkspaceMode.starters
    var automationEnabled = false

    /// List order is the explicit, editable priority when more than one mode matches.
    func automaticMode(in environment: WorkspaceEnvironment) -> WorkspaceMode? {
        guard automationEnabled else { return nil }
        return modes.first { $0.rule.matches(environment) }
    }
}

/// A manual choice holds until the physical context changes or the user resumes rules.
struct WorkspaceAutomationState {
    private(set) var environment: WorkspaceEnvironment?
    private(set) var manualHold = false
    private(set) var lastAutomaticMode: UUID?

    mutating func holdManually() { manualHold = true; lastAutomaticMode = nil }
    mutating func resume() { manualHold = false; lastAutomaticMode = nil }
    mutating func decide(configuration: DesktopWorkspaceConfiguration, environment next: WorkspaceEnvironment) -> UUID? {
        if let environment, environment != next { manualHold = false }
        environment = next
        guard !manualHold, let mode = configuration.automaticMode(in: next) else {
            if configuration.automaticMode(in: next) == nil { lastAutomaticMode = nil }
            return nil
        }
        guard lastAutomaticMode != mode.id else { return nil }
        lastAutomaticMode = mode.id
        return mode.id
    }
}

/// Reserve exact titles before fallback so a missing window cannot steal a known match.
enum WorkspaceWindowMatching {
    static func plan(slots: [WorkspaceWindow], titles: [String], unavailable: Set<Int>) -> [UUID: Int] {
        var reserved = unavailable
        var matches: [UUID: Int] = [:]
        for slot in slots where !slot.title.isEmpty {
            if let index = titles.indices.first(where: { !reserved.contains($0) && titles[$0] == slot.title }) {
                matches[slot.id] = index
                reserved.insert(index)
            }
        }
        for slot in slots where matches[slot.id] == nil {
            let fallback = titles.indices.contains(slot.ordinal) && !reserved.contains(slot.ordinal)
                ? slot.ordinal : titles.indices.first { !reserved.contains($0) }
            if let index = fallback { matches[slot.id] = index; reserved.insert(index) }
        }
        return matches
    }
}
