import Foundation

enum MouseAppExceptionSupport {
    static func identity(bundleID: String?, executablePath: String) -> String? { bundleID ?? executablePath }
    static func isExecutablePathIdentity(_ value: String) -> Bool { value.hasPrefix("/") }
}

enum Shell {
    static let defaultTimeout: TimeInterval = 5
    static func run(_ path: String, _ args: [String], timeout: TimeInterval,
                    maxOutputBytes: Int, cancellation: BoundedProcessCancellation?) -> (status: Int32, output: String) {
        let result = BoundedProcessRunner.run(path, args, timeout: timeout,
                                              maxOutputBytes: maxOutputBytes, cancellation: cancellation)
        return (result.status, String(decoding: result.output, as: UTF8.self))
    }
}

@main struct AppUpdateDiscoveryTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("First.app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Second.app"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var partial: [URL] = []
        InstalledApps.forEachApplication(in: [root], shouldContinue: { partial.isEmpty }) { partial.append($0) }
        precondition(partial.count == 1, "cancellation stops the directory walk")
        var all: [URL] = []
        InstalledApps.forEachApplication(in: [root]) { all.append($0) }
        precondition(all.count == 2, "other consumers still get the complete walk")
        print("App discovery: 2 checks passed")
    }
}
