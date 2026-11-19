import Foundation

@main struct AppUpdateScanLifetimeTests {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard value() else { fatalError(message) }
        }
        let old = AppUpdateScanLifetime()
        var started = 0, cancelled = 0, cacheWrites = 0
        expect(old.start { _ in started += 1; return { cancelled += 1 } }, "first feed starts")
        expect(old.start { _ in started += 1; return { cancelled += 1 } }, "second feed starts")
        old.cancel()
        expect(cancelled == 2 && !old.isActive, "off cancels every running feed")
        old.cancel()
        expect(cancelled == 2, "cancellation happens once")
        expect(!old.start { _ in started += 1; return nil }, "next feed batch must not start")
        expect(!old.whileActive { cacheWrites += 1 } && cacheWrites == 0, "old result cannot write cache")
        let current = AppUpdateScanLifetime()
        expect(current.start { _ in started += 1; return { cancelled += 10 } }, "new scan can start after re-enable")
        expect(!old.start { _ in started += 100; return nil } && current.isActive, "old scan cannot revive or cancel new scan")
        expect(current.whileActive { cacheWrites += 1 } && cacheWrites == 1, "new scan can update cache")
        current.finish()
        expect(!current.isActive && cancelled == 2, "successful finish releases rather than cancels")

        let completed = AppUpdateScanLifetime()
        var completedID: UUID?
        var completedCancellation = false
        completed.start { id in completedID = id; return { completedCancellation = true } }
        completed.finishRequest(completedID!)
        completed.cancel()
        expect(!completedCancellation, "finished requests release their cancellation handles")

        let queued = AppUpdateScanLifetime()
        queued.cancel()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = BoundedProcessRunner.run("/usr/bin/touch", [marker.path], timeout: 2,
                                     maxOutputBytes: 1024, cancellation: queued.commandCancellation)
        expect(!FileManager.default.fileExists(atPath: marker.path), "cancelled queued command must not launch")

        let running = AppUpdateScanLifetime()
        let commandDone = DispatchSemaphore(value: 0)
        let commandStarted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            commandStarted.signal()
            _ = BoundedProcessRunner.run("/bin/sleep", ["30"], timeout: 35,
                                         maxOutputBytes: 1024, cancellation: running.commandCancellation)
            commandDone.signal()
        }
        commandStarted.wait()
        // Cancellation is correct whether it wins before launch or interrupts the child.
        running.cancel()
        expect(commandDone.wait(timeout: .now() + 4) == .success, "cancelled command does not wait for its normal timeout")

        let racing = AppUpdateScanLifetime()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchGroup(), lock = NSLock()
        var raceCancelled = false
        finished.enter()
        DispatchQueue.global().async {
            racing.start { _ in
                entered.signal()
                release.wait()
                return { lock.lock(); raceCancelled = true; lock.unlock() }
            }
            finished.leave()
        }
        entered.wait()
        finished.enter()
        DispatchQueue.global().async { racing.cancel(); finished.leave() }
        release.signal()
        expect(finished.wait(timeout: .now() + 3) == .success, "concurrent cancel completes")
        lock.lock(); let didCancel = raceCancelled; lock.unlock()
        expect(didCancel && !racing.isActive, "a request starting during cancellation is cancelled")

        let batchLifetime = AppUpdateScanLifetime()
        let batchQueue = DispatchQueue(label: "test.app-update-feed-batches")
        let batchStarted = DispatchSemaphore(value: 0), batchDone = DispatchSemaphore(value: 0)
        let batchLock = NSLock()
        var requested: [Int] = [], completions: [() -> Void] = []
        batchQueue.async {
            AppUpdateBatchScheduler.run(Array(0..<7), batchSize: 4, lifetime: batchLifetime,
                                        queue: batchQueue, beforeDeadline: { true }) { item, done in
                let didStart = batchLifetime.start { _ in
                    batchLock.lock(); requested.append(item); completions.append(done); batchLock.unlock()
                    return nil
                }
                if !didStart { done() }
                if item == 3 { batchStarted.signal() }
            } completion: { _ in batchDone.signal() }
        }
        expect(batchStarted.wait(timeout: .now() + 3) == .success, "first feed batch starts")
        batchLifetime.cancel()
        batchLock.lock(); let firstBatch = completions; batchLock.unlock()
        firstBatch.forEach { $0() }
        expect(batchDone.wait(timeout: .now() + 3) == .success, "cancelled batch completes")
        batchLock.lock(); let actualRequested = requested; batchLock.unlock()
        expect(actualRequested == [0, 1, 2, 3], "no feeds from the next batch start after off")
        print("App Updates scan lifetime: \(checks) checks passed")
    }
}
