import AppKit

final class FixtureApp {
    let processIdentifier: pid_t
    var isTerminated = false
    init(_ pid: pid_t) { processIdentifier = pid }
}

final class FixtureWorkspace {
    static let shared = FixtureWorkspace()
    var frontmostApplication: FixtureApp?
}

enum FixtureSettings {
    static var accessibility = true
    static var secureInput = false
    static func beep() {}
}

final class FixtureEventSource {
    static var held: CGEventFlags = []
    init?(stateID: CGEventSourceStateID) {}
    static func flagsState(_ state: CGEventSourceStateID) -> CGEventFlags { held }
}

final class FixtureKeyboardEvent {
    static var posts: [(pid_t, Bool)] = []
    private let down: Bool
    var flags: CGEventFlags = []
    init?(keyboardEventSource: FixtureEventSource, virtualKey: CGKeyCode, keyDown: Bool) { down = keyDown }
    func postToPid(_ pid: pid_t) {
        precondition(flags == .maskCommand)
        Self.posts.append((pid, down))
    }
}

final class FixturePasteboard: ClipboardHistoryPasteboard {
    static let shared = FixturePasteboard()
    var changeCount = 1
    var writes = 0
    var clears = 0
    var onClear: (() -> Void)?
    func clearContents() -> Int {
        clears += 1
        changeCount += 1
        onClear?()
        return changeCount
    }
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool { writes += 1; return true }
    func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool { writes += 1; return true }
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool { writes += 1; return true }
}

final class FixtureAccess {
    static let shared = FixtureAccess()
    var pending: (() -> Void)?
    var afterRead: (() -> Void)?
    func async<T>(timeout: TimeInterval, _ work: @escaping (() -> Bool) -> T?, then: @escaping (T?) -> Void,
                  didFinish: @escaping (T?) -> Void = { _ in }) {
        precondition(pending == nil)
        pending = {
            let result = work { false }
            self.afterRead?()
            self.afterRead = nil
            didFinish(result)
            then(result)
        }
    }
    func deliver() {
        let work = pending
        pending = nil
        work?()
    }
}

struct ClipboardHistoryEntry {
    let id = UUID()
    let text: String
}

final class ClipboardHistoryService {
    static let shared = ClipboardHistoryService()
    static let gate = ClipboardPresentationGate()
    var cleared: [UUID: Date]?
    static let pasteboardTimeout = 1.0
    var copyInFlight = false
    var latestPasteboardEntry: ClipboardHistoryEntry?
    var lastChangeCount = 0
    var touched: [UUID] = []

    static func availabilityTicket() -> UUID? { gate.capture(currentlyAvailable: true) }
    static func acceptsAvailabilityTicket(_ ticket: UUID) -> Bool { gate.accepts(ticket, currentlyAvailable: true) }
    static func plannedWrite(for items: [ClipboardHistoryEntry]) -> ClipboardHistoryWrite? {
        items.first.map { .text($0.text) }
    }
    func touch(_ ids: [UUID]) { touched.append(contentsOf: ids) }
    func clearRecent(_ ids: [UUID: Date]) { cleared = ids }
}

@main
enum UtilityClipboardPasteLifecycleTests {
    @MainActor
    static func main() async {
        let gate = ClipboardPresentationGate()
        let board = FixturePasteboard.shared
        let access = FixtureAccess.shared
        let app = FixtureApp(42)
        let other = FixtureApp(7)
        let workspace = FixtureWorkspace.shared
        workspace.frontmostApplication = app

        let retired = gate.capture(currentlyAvailable: true)!
        gate.update(available: false)
        gate.update(available: true)
        let write = ClipboardHistoryWrite.text("fixture value")
        precondition(write.write(to: board, isExpired: { false },
                                 isAuthorized: { gate.accepts(retired, currentlyAvailable: true) }) == nil)
        precondition(board.clears == 0)

        let accepted = gate.capture(currentlyAvailable: true)!
        board.onClear = { gate.update(available: false) }
        let acceptedWrite = write.write(to: board, isExpired: { false },
                                        isAuthorized: { gate.accepts(accepted, currentlyAvailable: true) })
        precondition(acceptedWrite?.succeeded == true && board.writes == 1)
        board.onClear = nil
        gate.update(available: true)

        let ticket = gate.capture(currentlyAvailable: true)!
        let allowed = { gate.accepts(ticket, currentlyAvailable: true) }
        ClipboardHistoryPaste.schedule(to: app, expectedChangeCount: board.changeCount, whileAllowed: allowed)
        await until { access.pending != nil }
        access.afterRead = { workspace.frontmostApplication = other }
        access.deliver()
        precondition(FixtureKeyboardEvent.posts.isEmpty)
        workspace.frontmostApplication = app

        ClipboardHistoryPaste.schedule(to: app, expectedChangeCount: board.changeCount, whileAllowed: allowed)
        await until { access.pending != nil }
        board.changeCount += 1
        access.deliver()
        precondition(FixtureKeyboardEvent.posts.isEmpty)

        ClipboardHistoryPaste.schedule(to: app, expectedChangeCount: board.changeCount, whileAllowed: allowed)
        await until { access.pending != nil }
        FixtureSettings.secureInput = true
        access.deliver()
        precondition(FixtureKeyboardEvent.posts.isEmpty)
        FixtureSettings.secureInput = false

        ClipboardHistoryPaste.schedule(to: app, expectedChangeCount: board.changeCount, whileAllowed: allowed)
        await until { access.pending != nil }
        access.afterRead = {
            gate.update(available: false)
            gate.update(available: true)
        }
        access.deliver()
        precondition(FixtureKeyboardEvent.posts.isEmpty)

        let resumed = gate.capture(currentlyAvailable: true)!
        FixtureEventSource.held = .maskCommand
        ClipboardHistoryPaste.schedule(to: app, expectedChangeCount: board.changeCount) {
            gate.accepts(resumed, currentlyAvailable: true)
        }
        try? await Task.sleep(for: .milliseconds(200))
        precondition(access.pending == nil)
        FixtureEventSource.held = []
        await until { access.pending != nil }
        access.deliver()
        precondition(FixtureKeyboardEvent.posts.count == 2)
        precondition(FixtureKeyboardEvent.posts.allSatisfy { $0.0 == app.processIdentifier })
        precondition(FixtureKeyboardEvent.posts.map(\.1) == [true, false])

        let history = ClipboardHistoryService.shared
        let entry = ClipboardHistoryEntry(text: "accepted copy fixture")
        let before = board.clears
        var copied: Bool?
        history.copy(entry) { copied = $0 }
        precondition(history.copyInFlight)
        ClipboardHistoryService.gate.update(available: false)
        ClipboardHistoryService.gate.update(available: true)
        access.deliver()
        precondition(copied == false && board.clears == before && !history.copyInFlight)

        history.copy(entry) { copied = $0 }
        board.onClear = { ClipboardHistoryService.gate.update(available: false) }
        access.deliver()
        precondition(copied == true && board.clears == before + 1)
        precondition(history.lastChangeCount == board.changeCount && !history.copyInFlight)
        precondition(history.latestPasteboardEntry == nil && history.touched.isEmpty)
        board.onClear = nil
        ClipboardHistoryService.gate.update(available: true)

        let confirmed = [UUID(): Date()]
        let confirmation = ClipboardHistoryService.availabilityTicket()!
        ClipboardHistoryService.gate.update(available: false)
        ClipboardHistoryService.gate.update(available: true)
        confirmClearInCommandBar(clipboardTicket: confirmation, recentIDs: confirmed)
        precondition(ClipboardHistoryService.shared.cleared == nil)
        confirmClearInCommandBar(clipboardTicket: ClipboardHistoryService.availabilityTicket()!, recentIDs: confirmed)
        precondition(ClipboardHistoryService.shared.cleared == confirmed)
        print("Utility clipboard admission, paste delivery, and clear confirmation passed")
    }

    private static func until(_ ready: () -> Bool) async {
        for _ in 0..<160 {
            if ready() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Timed out waiting for the pasteboard lane")
    }
}
