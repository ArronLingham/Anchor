import Foundation
import Combine
import XCTest
@testable import AnchorUtilities

final class SystemToolsTests: XCTestCase {
    @MainActor
    func testSharedMonitorStopsAfterLastVisibleConsumerAndIgnoresHiddenPins() {
        let monitor = SystemMonitor.shared
        let defaults = UserDefaults(suiteName: "Anchor.SystemToolsTests.\(UUID())")!
        defaults.set(true, forKey: AppFeature.monitorCPU.availabilityKey)
        defaults.set(true, forKey: AppFeature.monitorNetwork.availabilityKey)
        defaults.set(true, forKey: DefaultsKey.menuBarCPU)
        defaults.set(true, forKey: DefaultsKey.menuBarNetwork)
        defaults.set(true, forKey: DefaultsKey.monitorAlertCPU)
        XCTAssertTrue(monitor.requestedSamplingKinds(defaults: defaults).isEmpty)
        let first = UUID(), second = UUID()
        monitor.acquireAnchorStats(first); monitor.acquireAnchorStats(second)
        XCTAssertTrue(monitor.hasScheduledSampling)
        XCTAssertTrue(monitor.requestedSamplingKinds(defaults: defaults).contains("network"))
        XCTAssertTrue(monitor.requestedSamplingKinds(defaults: defaults).contains("temperature"))
        monitor.releaseAnchorStats(first)
        XCTAssertTrue(monitor.hasScheduledSampling, "Another visible surface still needs readings")
        monitor.releaseAnchorStats(second)
        XCTAssertFalse(monitor.hasScheduledSampling, "The timer itself must disappear, not no-op")
        XCTAssertTrue(monitor.requestedSamplingKinds(defaults: defaults).isEmpty)
        monitor.releaseAnchorStats(second)
        XCTAssertFalse(monitor.hasScheduledSampling)
    }

    func testNetworkReopenDoesNotAverageOverHiddenTraffic() {
        var counters = NetworkCounters(received: 1_000, sent: 500)
        let sampler = NetworkSampler(counterReader: { counters }, processReader: { nil })
        XCTAssertNil(sampler.sample(now: 1).downBytesPerSec)
        counters = NetworkCounters(received: 3_000, sent: 1_500)
        XCTAssertEqual(sampler.sample(now: 3).downBytesPerSec, 1_000)
        sampler.resetBaseline()
        counters = NetworkCounters(received: 1_003_000, sent: 501_500)
        XCTAssertNil(sampler.sample(now: 4).downBytesPerSec, "Even a one-second close drops the baseline")
        counters = NetworkCounters(received: 1_005_000, sent: 502_500)
        let next = sampler.sample(now: 6)
        XCTAssertEqual(next.downBytesPerSec, 1_000)
        XCTAssertEqual(next.upBytesPerSec, 500)
        XCTAssertEqual(next.totalDown, 4_000, "Hidden bytes do not enter monitored totals")
    }

    func testAnchorDataAndSystemFilesAreNeverCleanupCandidates() {
        for name in ["com.arronlingham.Anchor", "com.arronlingham.Anchor.utilities", "COM.ARRONLINGHAM.ANCHOR.dev"] {
            XCTAssertTrue(CleanerPolicy.isExcludedCacheEntry(name))
            XCTAssertFalse(CleanerPolicy.precheckCacheEntry(name))
            XCTAssertTrue(CleanerSupport.isProtectedBundleID(name))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in ["/System/a", "/Library/a", "/private/a", "/Applications/App.app/a", home.path + "/.codex/a", home.path + "/Library/a", home.path + "/.Trash/a", home.path + "/projects/foo/.git/objects/a"] {
            XCTAssertTrue(StorageReview.isProtected(URL(fileURLWithPath: path)), path)
        }
        XCTAssertFalse(StorageReview.isProtected(home.appendingPathComponent("Downloads/large-movie.mov")))
    }

    func testCodexEvidenceRejectsQuotedLimitsAndClearsAfterProgress() throws {
        let id = UUID().uuidString
        let now = Date()
        var evidence = CodexRecoveryEvidence()
        func line(_ type: String, _ payload: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": now.ISO8601Format(), "payload": payload])
        }
        evidence.consume(try line("session_meta", ["id": id]), now: now)
        XCTAssertEqual(evidence.sessionID, id)
        for type in ["response_item", "user", "assistant"] {
            evidence.consume(try line(type, ["type": "error", "message": "You've hit your usage limit."]), now: now)
            XCTAssertNil(evidence.blockedAt)
        }
        evidence.consume(try line("event_msg", ["type": "error", "message": "Network error"]), now: now)
        XCTAssertNil(evidence.blockedAt)
        evidence.consume(try line("event_msg", ["type": "error", "codex_error_info": "usage_limit_exceeded"]), now: now)
        XCTAssertNotNil(evidence.blockedAt)
        evidence.consume(try line("event_msg", ["type": "task_started"]), now: now)
        XCTAssertNil(evidence.blockedAt)
        evidence.consume(try line("session_meta", ["id": id, "dynamic_tools": [["name": "app_tool"]]]), now: now)
        XCTAssertTrue(evidence.hasDynamicTools)
    }

    func testCodexWaitsForEveryExhaustedWindowAndOnlyResumesFailedLimitTurns() {
        let now = Date()
        func window(_ percent: Double, _ reset: Date?) -> AgentLimitWindow {
            AgentLimitWindow(id: UUID().uuidString, kind: .session, minutes: 300, scope: nil, usedPercent: percent, resetsAt: reset)
        }
        XCTAssertNil(CodexRecoveryEvidence.resetDate([window(99, now)], now: now))
        XCTAssertNil(CodexRecoveryEvidence.resetDate([window(100, nil)], now: now))
        XCTAssertEqual(CodexRecoveryEvidence.resetDate([window(100, now.addingTimeInterval(60)), window(100, now.addingTimeInterval(600))], now: now), now.addingTimeInterval(600))
        let error: [String: Any] = ["codexErrorInfo": "usageLimitExceeded", "message": "Usage limit"]
        for status in ["completed", "interrupted", "inProgress"] {
            XCTAssertFalse(CodexRecoveryEvidence.latestTurnIsLimited(["status": status, "error": error]))
        }
        XCTAssertTrue(CodexRecoveryEvidence.latestTurnIsLimited(["status": "failed", "error": error]))
        XCTAssertFalse(CodexRecoveryEvidence.latestTurnIsLimited(["status": "failed", "error": ["message": "Network failed"]]))
    }
    @MainActor
    func testLiveHardwareSampleArrivesAndStopsWithItsLease() async {
        let stats = UtilitySystemStats.shared
        let received = expectation(description: "Fresh CPU, memory and network readings")
        var seen = false
        let observation = stats.$reading.sink { value in
            if !seen, value.cpuPercent != nil, value.memoryTotalBytes > 0, value.networkInBytesPerSecond != nil {
                seen = true
                print("Hardware: CPU temperature \(String(describing: value.cpuTemperature)), GPU temperature \(String(describing: value.gpuTemperature)), battery temperature \(String(describing: value.batteryTemperature)), pressure \(value.memoryPressure)")
                received.fulfill()
            }
        }
        stats.acquire()
        await fulfillment(of: [received], timeout: 8)
        stats.release()
        observation.cancel()
        XCTAssertFalse(SystemMonitor.shared.hasScheduledSampling)
    }

    @MainActor
    func testStorageReviewSkipsLinksPackagesAndChangedFiles() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".anchor-storage-test-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let filename = "anchor-storage-fixture-" + UUID().uuidString + ".bin"
        let file = root.appendingPathComponent(filename)
        try Data(repeating: 65, count: 8192).write(to: file)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.bin"), withDestinationURL: file)
        let app = root.appendingPathComponent("Fixture.app/Contents")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(repeating: 66, count: 8192).write(to: app.appendingPathComponent("inside.bin"))
        let review = StorageReview(minimumBytes: 1024)
        let scanned = expectation(description: "Metadata inventory")
        let observation = review.$scanning.dropFirst().sink { if !$0 { scanned.fulfill() } }
        review.scan(root: root)
        await fulfillment(of: [scanned], timeout: 5)
        observation.cancel()
        XCTAssertEqual(review.items.map(\.url.lastPathComponent), [filename])
        XCTAssertTrue(review.selected.isEmpty, "Personal files never start selected")
        review.selected.insert(file.path)
        // A changed file must be retained without invoking a Trash operation.
        try Data(repeating: 67, count: 16384).write(to: file)
        let finished = expectation(description: "Changed file retained")
        let removal = review.$removing.dropFirst().sink { if !$0 { finished.fulfill() } }
        review.trashSelected()
        await fulfillment(of: [finished], timeout: 5)
        removal.cancel()
        XCTAssertTrue(fm.fileExists(atPath: file.path))
        XCTAssertTrue(review.message?.contains("0 files") == true)
        review.scan(root: root)
        review.cancel()
        XCTAssertFalse(review.scanning)
    }

    func testCodexConversationPreservesInterleavedApprovalRequests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anchor-codex-rpc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/python3
        import json,sys
        for line in sys.stdin:
            request=json.loads(line)
            if 'id' not in request: continue
            if request['method']=='turn/start':
                print(json.dumps({'id':99,'method':'item/commandExecution/requestApproval','params':{}}),flush=True)
                result={'turn':{'id':'fixture-turn'}}
            else: result={}
            print(json.dumps({'id':request['id'],'result':result}),flush=True)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let conversation = try XCTUnwrap(AgentCodexConversation(executable, environment: [:], timeout: 10, recovery: true))
        defer { conversation.end() }
        _ = try conversation.start().get()
        let response = try conversation.ask("turn/start", ["threadId": "fixture", "input": []]).get()
        XCTAssertEqual((response["turn"] as? [String: Any])?["id"] as? String, "fixture-turn")
        XCTAssertTrue(conversation.serverRequestSeen, "Recovery must stop for a request even when it arrived before turn/start's reply")
    }

    func testCleaningUnlockIgnoresRepeatAndRequiresDeliberateEscapes() {
        var unlock = CleaningUnlockCounter(requiredKeyCode: 53, threshold: 5, pressWindow: 6)
        for n in 0..<10 { XCTAssertFalse(unlock.registerKeyDown(code: 53, time: Double(n), isRepeat: true)) }
        XCTAssertEqual(unlock.progress, 0)
        for n in 0..<4 { XCTAssertFalse(unlock.registerKeyDown(code: 53, time: Double(n), isRepeat: false)) }
        XCTAssertFalse(unlock.registerKeyDown(code: 0, time: 4, isRepeat: false))
        XCTAssertEqual(unlock.progress, 0)
        for n in 5..<9 { XCTAssertFalse(unlock.registerKeyDown(code: 53, time: Double(n), isRepeat: false)) }
        XCTAssertTrue(unlock.registerKeyDown(code: 53, time: 9, isRepeat: false))
    }

    func testCodexCancellationEndsABlockedRPC() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anchor-codex-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/python3
        import json,sys
        for line in sys.stdin:
            request=json.loads(line)
            if request.get('method')=='initialize':
                print(json.dumps({'id':request['id'],'result':{}}),flush=True)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let flag = CleanerSupport.ScanCancellation()
        let conversation = try XCTUnwrap(AgentCodexConversation(executable, environment: [:], timeout: 3600, recovery: true, cancellation: flag))
        defer { conversation.end() }
        _ = try conversation.start().get()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { flag.cancel() }
        let began = Date()
        XCTAssertThrowsError(try conversation.ask("fixture/neverReplies").get())
        XCTAssertLessThan(Date().timeIntervalSince(began), 2, "A disabled recovery must not remain blocked on the six-hour active-turn deadline")
    }

}
