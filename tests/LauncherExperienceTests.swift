import Foundation

@main struct LauncherExperienceTests {
    static func main() throws {
        var stream = LunarMessageStream()
        let first = try stream.append(Data("{\"display\":1,\"bright".utf8))
        precondition(first.isEmpty)
        let batch = try stream.append(Data("ness\":0.5}\n{\"display\":2,\"brightness\":0.8}\n".utf8))
        precondition(batch.map(\.display) == [1, 2])
        precondition(batch[0].brightness == 0.5)
        let next = try stream.append(Data("\nnoise\n{\"display\":3,\"volume\":0.3}".utf8))
        precondition(next.count == 1 && next[0].display == 3)
        do {
            _ = try stream.append(Data(repeating: 65, count: 65537))
            fatalError("Must reject an unbounded malformed stream")
        } catch LunarMessageStream.StreamError.oversizedMessage {}

        var recovery = LunarDisplayRecoveryState()
        precondition(!recovery.observe([]))
        precondition(recovery.observe(["2:monitor-a"]))
        for _ in 0..<100 { precondition(!recovery.observe(["2:monitor-a"])) }
        precondition(recovery.observe(["2:monitor-a"], force: true))
        precondition(recovery.observe([]))
        precondition(!recovery.observe([], force: true))
        precondition(recovery.observe(["2:monitor-a"]))
        precondition(recovery.observe(["2:monitor-b"])) // reused display ID
        precondition(LunarDisplayRecoveryState.refreshSucceeded(Data("\n".utf8)))
        precondition(!LunarDisplayRecoveryState.refreshSucceeded(Data()))
        precondition(!LunarDisplayRecoveryState.refreshSucceeded(Data("Unauthorized\n".utf8)))
        precondition(!LunarDisplayRecoveryState.refreshSucceeded(Data("Status-Code: 1\r\n\n".utf8)))
        precondition(!LunarDisplayRecoveryState.refreshSucceeded(Data("Unknown command\n".utf8)))

        var laptop = LauncherWidgetProfile()
        laptop.order = ["music", "reminders", "calendar", "weather", "clock"]
        laptop.sizes = ["music": 2, "calendar": 0]
        var storage = laptop.saving(in: Data(), screen: "laptop")
        var monitor = LauncherWidgetProfile()
        monitor.sizes = ["music": 0]
        storage = monitor.saving(in: storage, screen: "monitor")
        precondition(LauncherWidgetProfile.load(storage, screen: "laptop") == laptop)
        precondition(LauncherWidgetProfile.load(storage, screen: "monitor") == monitor)
        precondition(LauncherWidgetProfile.load(storage, screen: "new") == LauncherWidgetProfile())
        precondition(LauncherWidgetProfile.load(Data("broken".utf8), screen: "laptop") == LauncherWidgetProfile())
        laptop.order = ["music", "music", "removed"]
        storage = laptop.saving(in: storage, screen: "laptop")
        let repaired = LauncherWidgetProfile.load(storage, screen: "laptop")
        precondition(repaired.order.count == 5 && Set(repaired.order).count == 5 && repaired.order.first == "music")
        print("Passed: fragmented/batched Lunar events, bounded invalid input, hot-plug/wake recovery, notification storms, rejected repair errors, per-display persistence, missing/corrupt profile recovery.")
    }
}
