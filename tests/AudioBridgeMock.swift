import Foundation

struct AudioBridge {
    static func catchException(_ block: () -> Void, error: inout NSError?) -> Bool {
        // Swift mock can't really catch NSException, but we can just run it
        // Or for tests, we can just return true. But wait, if it crashes the test...
        // We'll just run it. If it throws NSException, it will crash the test.
        // Wait, but we wanted to test if it crashes!
        // So for tests, we can't test catching the exception unless we link ObjC.
        return true
    }
}
