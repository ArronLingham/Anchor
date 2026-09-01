/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// Apps the user never wants quit when their last window closes.
///
/// This exists because the feature it guards terminates *other people's*
/// applications. A list the user cannot edit would mean the only way to protect
/// an app is to switch the whole feature off, which is not a real choice for
/// anyone who has one app that must stay running.
struct QuitOnCloseExclusions: View {
    @Default(.quitOnCloseExcludedApps) private var excluded
    @State private var isPickingApp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if excluded.isEmpty {
                Text("No exclusions. Finder, the Dock and Anchor itself are always excluded and are not listed here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(excluded, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        icon(for: bundleID)
                            .resizable()
                            .frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(displayName(for: bundleID))
                            // The bundle id is what actually matches, so it is
                            // shown: two apps can share a display name, and a
                            // user removing the wrong row would silently
                            // re-expose the app they meant to protect.
                            Text(bundleID)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            excluded.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Stop protecting this app")
                    }
                }
            }

            Button("Add app…") { isPickingApp = true }
                .fileImporter(
                    isPresented: $isPickingApp,
                    allowedContentTypes: [.application],
                    allowsMultipleSelection: true
                ) { result in
                    guard case .success(let urls) = result else { return }
                    for url in urls {
                        guard let id = Bundle(url: url)?.bundleIdentifier,
                              !excluded.contains(id)
                        else { continue }
                        excluded.append(id)
                    }
                }
        }
    }

    private func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            // The app has been removed since it was excluded. Keep the entry —
            // deleting it silently would un-protect a reinstall.
            return "(not installed)"
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func icon(for bundleID: String) -> Image {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return Image(systemName: "questionmark.app") }
        return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
    }
}
