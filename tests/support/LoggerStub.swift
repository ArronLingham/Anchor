// Minimal stand-in for DynamicIsland/utils/Logger.swift.
//
// The real Logger pulls in SwiftUI and the Defaults package to read a
// configured log level. The watcher only ever calls Logger.log, so the tests
// substitute this rather than dragging the SPM graph into a swiftc invocation.
// Output goes to stderr so it cannot be mistaken for test results on stdout.

import Foundation

enum LogCategory: String {
    case lifecycle, memory, performance, ui, network
    case error, warning, success, debug, extensions
}

struct Logger {
    static func log(
        _ message: String,
        category: LogCategory,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        FileHandle.standardError.write(Data("[\(category.rawValue)] \(message)\n".utf8))
    }
}
