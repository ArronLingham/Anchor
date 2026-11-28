import Darwin
import Foundation
import SwiftTerm

@main
enum TerminalPTYTests {
    static func main() {
        let pidFile = URL(fileURLWithPath: CommandLine.arguments[1])
        let session = HeadlessTerminal { _ in }
        session.process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "/bin/sleep 8 & child=$!; printf '%s\\n' \"$child\" > \"$1\"; wait \"$child\"", "fixture", pidFile.path],
            environment: ["PATH=/usr/bin:/bin"]
        )
        let shell = session.process.shellPid
        guard shell > 0,
              until({ FileManager.default.fileExists(atPath: pidFile.path) }),
              let contents = try? String(contentsOf: pidFile, encoding: .utf8),
              let child = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
              child > 0, kill(child, 0) == 0 else { fatalError("The fixture shell did not start its child") }

        session.process.terminate()
        TerminalShellReaper.reapOnExit(shell)
        precondition(until({ hasExited(child) }), "A child of the disposable shell kept running")
        precondition(until({ hasExited(shell) }), "The disposed shell was not collected")
        print("SwiftTerm PTY closed, fixture child exited, and shell was collected")
    }

    private static func hasExited(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    private static func until(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
