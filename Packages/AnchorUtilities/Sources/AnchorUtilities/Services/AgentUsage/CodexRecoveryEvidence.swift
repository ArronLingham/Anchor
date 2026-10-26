import Foundation

/// Only provider-written limit failures qualify. User messages, tool output,
/// assistant prose, generic errors and manual interruptions never qualify.
struct CodexRecoveryEvidence {
    var sessionID = ""
    var hasDynamicTools = false
    var windows: [AgentLimitWindow] = []
    var blockedAt: Date?

    mutating func consume(_ line: Data, now: Date) {
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = json["type"] as? String,
              let payload = json["payload"] as? [String: Any] else { return }
        if type == "session_meta" {
            sessionID = payload["id"] as? String ?? ""
            hasDynamicTools = !(payload["dynamic_tools"] as? [Any] ?? []).isEmpty
            // Subagents are never resumed independently of their parent.
            if payload["source"] is [String: Any] { hasDynamicTools = true }
            return
        }
        guard type == "event_msg", let event = payload["type"] as? String else { return }
        if event == "token_count", let limits = payload["rate_limits"] as? [String: Any],
           AgentLogParser.isMainBucket(limits) {
            windows = AgentLogParser.codexWindows(limits, observed: now) ?? []
        } else if event == "error" {
            let code = payload["codex_error_info"] as? String ?? payload["code"] as? String ?? ""
            let message = payload["message"] as? String ?? ""
            if Self.isUsageLimit(code: code, message: message) {
                blockedAt = AgentLogParser.timestamp(json["timestamp"]) ?? now
            }
        } else if ["task_started", "task_complete", "agent_message"].contains(event) {
            // Progress or an intentional stop supersedes old evidence. An error
            // remains eligible only when it is the terminal event in this tail.
            blockedAt = nil
        }
    }
    static func isUsageLimit(code: String, message: String) -> Bool {
        ["usageLimitExceeded", "usage_limit_exceeded", "usage_limit_reached"].contains(code)
            || message.hasPrefix("You've hit your usage limit.")
            || message.hasPrefix("You have hit your usage limit.")
    }
    static func latestTurnIsLimited(_ turn: [String: Any]) -> Bool {
        guard turn["status"] as? String == "failed", let error = turn["error"] as? [String: Any] else { return false }
        return isUsageLimit(code: error["codexErrorInfo"] as? String ?? "", message: error["message"] as? String ?? "")
    }
    static func resetDate(_ windows: [AgentLimitWindow], now: Date) -> Date? {
        let exhausted = windows.filter { $0.usedPercent >= 100 }
        guard !exhausted.isEmpty, exhausted.allSatisfy({ $0.resetsAt != nil }) else { return nil }
        // Both the session AND weekly allowance must be available again.
        return exhausted.compactMap(\.resetsAt).max()
    }
}
