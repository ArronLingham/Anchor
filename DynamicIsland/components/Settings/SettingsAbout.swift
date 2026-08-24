/*
 * Atoll (DynamicIsland)
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
import AVFoundation
import Combine
import Defaults
import EventKit
import KeyboardShortcuts
import LaunchAtLogin
import LottieUI
import Sparkle
import SwiftUI
import SwiftUIIntrospect
import UniformTypeIdentifiers

// Extracted from SettingsView.swift, originally created by
// Richard Kunkli on 07/08/2024. Behaviour unchanged.

struct About: View {
    @State private var showBuildNumber: Bool = false
    @Default(.updateChannel) var updateChannel
    let updaterController: SPUStandardUpdaterController
    @Environment(\.openWindow) var openWindow
    var body: some View {
        VStack {
            Form {
                Section {
                    HStack {
                        Text("Release name")
                        Spacer()
                        Text(Defaults[.releaseName])
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()

                        // Channel badge
                        Text(UpdateChannel.buildChannel.displayName)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(UpdateChannel.buildChannel.badgeColor).opacity(0.2))
                            .foregroundStyle(Color(UpdateChannel.buildChannel.badgeColor))
                            .clipShape(Capsule())

                        if showBuildNumber {
                            Text("(\(Bundle.main.buildVersionNumber ?? ""))")
                                .foregroundStyle(.secondary)
                        }
                        Text(Bundle.main.releaseVersionNumber ?? "unkown")
                            .foregroundStyle(.secondary)
                    }
                    .onTapGesture {
                        withAnimation {
                            showBuildNumber.toggle()
                        }
                    }
                } header: {
                    Text("Version info")
                }

                UpdaterSettingsView(updater: updaterController.updater)

                HStack(spacing: 30) {
                    Spacer(minLength: 0)
                    Button {
                        NSWorkspace.shared.open(sponsorPage)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "cup.and.saucer.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.primary)
                                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            Text("Donate")
                                .foregroundStyle(.primary)
                        }
                        .contentShape(Rectangle())
                    }
                    Spacer(minLength: 0)
                    Button {
                        NSWorkspace.shared.open(productPage)
                    } label: {
                        VStack(spacing: 5) {
                            Image("Github")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 18)
                                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            Text("GitHub")
                                .foregroundStyle(.primary)
                        }
                        .contentShape(Rectangle())
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(PlainButtonStyle())
                
                Text("Your support funds software development learning for students in 9th–12th grade.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 5)

                Section {
                    ForEach(UpdateChannel.availableChannels) { channel in
                        Button {
                            updateChannel = channel
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: channel.badgeIcon)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color(channel.badgeColor))
                                    .frame(width: 20, alignment: .center)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(channel.displayName)
                                        .foregroundStyle(.primary)
                                    Text(channel.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if updateChannel == channel {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color(channel.badgeColor))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Text("Current build: \(UpdateChannel.buildChannel.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Update channel")
                }
                VStack(spacing: 0) {
                    Divider()
                        .padding(.bottom, 5)
                    Text("Made with ❤️ by Ebullioscopic")
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 7)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .toolbar {
            //            Button("Welcome window") {
            //                openWindow(id: "onboarding")
            //            }
            //            .controlSize(.extraLarge)
            CheckForUpdatesView(updater: updaterController.updater)
        }
        .navigationTitle("About")
    }
}
