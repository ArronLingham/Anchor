enum LockScreenEventPolicy {
    /// Late notifications must not reverse a newer canonical session state.
    /// If macOS cannot provide a snapshot, retain the notification fallback.
    static func accepts(isLockedEvent: Bool, sessionIsLocked: Bool?) -> Bool {
        guard let sessionIsLocked else { return true }
        return isLockedEvent == sessionIsLocked
    }
}
