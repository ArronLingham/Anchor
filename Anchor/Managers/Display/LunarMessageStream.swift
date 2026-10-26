import Foundation

struct LunarDisplayData: Codable {
    var brightness: Float?
    var contrast: Float?
    var volume: Float?
    var mute: Bool?
    var nits: Float?
    var display: Int
}

/// Newline-delimited JSON can be fragmented or batched by TCP.
struct LunarMessageStream {
    private var buffer = Data()
    enum StreamError: Error { case oversizedMessage }

    mutating func append(_ data: Data) throws -> [LunarDisplayData] {
        buffer.append(data)
        var messages: [LunarDisplayData] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if let message = try? JSONDecoder().decode(LunarDisplayData.self, from: line) {
                messages.append(message)
            }
        }
        if let message = try? JSONDecoder().decode(LunarDisplayData.self, from: buffer) {
            buffer.removeAll(keepingCapacity: true)
            messages.append(message)
        }
        guard buffer.count <= 65536 else { throw StreamError.oversizedMessage }
        return messages
    }
}

/// Recovery is keyed by display identity, not screen-parameter notifications:
/// EDR and resolution updates can otherwise trigger an endless repair loop.
struct LunarDisplayRecoveryState {
    private var displays: Set<String> = []

    mutating func observe(_ snapshot: Set<String>, force: Bool = false) -> Bool {
        let changed = displays != snapshot
        displays = snapshot
        return changed || (force && !snapshot.isEmpty)
    }

    static func refreshSucceeded(_ reply: Data) -> Bool {
        !reply.isEmpty && reply.contains(10)
            && String(data: reply, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == ""
    }
}
