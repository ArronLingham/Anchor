// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum FeedbackKind: String, Codable, CaseIterable {
    case bug
    case feature
}

struct FeedbackDiagnostics: Codable {
    let appVersion: String
    let appBuild: String
    let macOS: String
    let macModel: String?
    let language: String
    let isBeta: Bool
    let updateChannel: String

    static func current() -> FeedbackDiagnostics {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let isBeta = AppInfo.isBeta
        let channel = AppInfo.isDeveloperBuild ? "developer" : (isBeta ? "beta" : (UpdateService.shared.includeBetaUpdates ? "beta-opt-in" : "stable"))
        return FeedbackDiagnostics(
            appVersion: AppInfo.version,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            macOS: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            macModel: modelIdentifier,
            language: L10n.shared.language.rawValue,
            isBeta: isBeta,
            updateChannel: channel
        )
    }

    private static let modelIdentifier: String? = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }()
}

private struct FeedbackSubmission: Codable {
    let kind: FeedbackKind
    let message: String
    let diagnostics: FeedbackDiagnostics?
}

enum FeedbackError: Error {
    case unavailable
    case rateLimited
    case rejected
    case invalidResponse
}

@MainActor
final class FeedbackService {
    static let shared = FeedbackService()

    /// The upstream upload service is not an Anchor feedback destination.
    /// Anchor's host presents its GitHub issue page or copies diagnostics locally.
    func submit(kind: FeedbackKind, message: String, diagnostics: FeedbackDiagnostics?) async throws {
        throw FeedbackError.unavailable
    }
}
