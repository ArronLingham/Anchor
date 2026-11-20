import AppKit
import Foundation

final class FixturePrompt {
    func dismiss(with: NSApplication.ModalResponse) {}
}
final class DiskImageInspectionFixture {
    let workQueue = DispatchQueue(label: "fixture.disk-inspection")
    var mountObserver: NSObjectProtocol? = NSObject()
    var inspectionSession = BoundedProcessCancellation()
    var pending: [Int] = []
    var processingMounts = Set<String>()
    var installPrompt: FixturePrompt?
    let firstStarted = DispatchSemaphore(value: 0)
    let secondStarted = DispatchSemaphore(value: 0)
    let firstReleased = DispatchSemaphore(value: 0)
    let secondReleased = DispatchSemaphore(value: 0)
    private var scans = 0
    func candidate(mountedAt: URL, session: BoundedProcessCancellation) -> Int? {
        scans += 1
        if scans == 1 { firstStarted.signal(); firstReleased.wait(); return 1 }
        secondStarted.signal(); secondReleased.wait(); return 2
    }
    func presentNextCandidate() {}
    func reenable() { inspectionSession = BoundedProcessCancellation(); mountObserver = NSObject() }
}

@main struct DiskImageInspectionLifecycleTests {
    @MainActor static func main() async {
        let fixture = DiskImageInspectionFixture()
        let mount = URL(fileURLWithPath: "/fixture/Sample")
        fixture.inspect(mountURL: mount)
        precondition(fixture.firstStarted.wait(timeout: .now() + 3) == .success)
        fixture.stop()
        fixture.reenable()
        fixture.inspect(mountURL: mount)
        fixture.firstReleased.signal()
        precondition(fixture.secondStarted.wait(timeout: .now() + 3) == .success)
        try? await Task.sleep(nanoseconds: 100_000_000)
        precondition(fixture.pending.isEmpty, "old scan must not publish after off/on")
        precondition(fixture.processingMounts.contains(mount.path), "old completion must not erase the replacement's mount marker")
        fixture.secondReleased.signal()
        for _ in 0..<30 {
            if fixture.pending == [2] { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(fixture.pending == [2], "current scan publishes its candidate")
        precondition(fixture.processingMounts.isEmpty, "current completion removes its own marker")
        fixture.stop()
        precondition(fixture.pending.isEmpty && fixture.inspectionSession.isCancelled, "off clears candidates and cancels inspection")
        let stdoutOnly = BoundedProcessRunner.run("/bin/sh", ["-c", "printf metadata; printf warning >&2"], timeout: 2,
                                                   maxOutputBytes: 1024, discardStandardError: true)
        precondition(String(decoding: stdoutOnly.output, as: UTF8.self) == "metadata", "diagnostics must not corrupt the plist stream")
        let combined = BoundedProcessRunner.run("/bin/sh", ["-c", "printf warning >&2"], timeout: 2, maxOutputBytes: 1024)
        precondition(String(decoding: combined.output, as: UTF8.self) == "warning", "other callers keep stderr capture")
        print("Disk-image inspection: 7 lifecycle and output checks passed")
    }
}
