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

/// Category library page: organizes all applications automatically into category tiles.
struct LauncherCategoryPageView: View {
    let onLaunch: (LauncherApp) -> Void
    @State private var selectedCategory: AppCategory?
    @ObservedObject private var index = AppIndex.shared
    @Environment(\.colorScheme) private var colorScheme

    private var activeCategories: [(category: AppCategory, apps: [LauncherApp])] {
        AppCategory.allCases.compactMap { cat in
            let catApps = index.apps(in: cat)
            return catApps.isEmpty ? nil : (category: cat, apps: catApps)
        }
    }

    var body: some View {
        ZStack {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 20)
                    ],
                    spacing: 20
                ) {
                    ForEach(activeCategories, id: \.category.id) { item in
                        LauncherCategoryBoxView(
                            category: item.category,
                            apps: item.apps,
                            onOpenCategory: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    selectedCategory = item.category
                                }
                            },
                            onLaunch: onLaunch
                        )
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
            }

            if let selected = selectedCategory {
                LauncherCategoryDetailView(
                    category: selected,
                    apps: index.apps(in: selected),
                    onClose: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            selectedCategory = nil
                        }
                    },
                    onLaunch: onLaunch
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .zIndex(10)
            }
        }
    }
}

/// A frosted card representing an application category with 2x2 preview icons.
struct LauncherCategoryBoxView: View {
    let category: AppCategory
    let apps: [LauncherApp]
    let onOpenCategory: () -> Void
    let onLaunch: (LauncherApp) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var previewApps: [LauncherApp] {
        Array(apps.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: category.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)

                Text(category.rawValue)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Text("\(apps.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                ForEach(previewApps) { app in
                    LauncherMiniAppIcon(app: app)
                        .onTapGesture {
                            onLaunch(app)
                        }
                }

                ForEach(0..<max(0, 4 - previewApps.count), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.clear)
                        .aspectRatio(1, contentMode: .fit)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            isHovered ? Color.accentColor.opacity(0.4) : Color.white.opacity(colorScheme == .dark ? 0.12 : 0.25),
                            lineWidth: 1
                        )
                )
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture {
            onOpenCategory()
        }
    }
}

/// Mini icon tile used in category 2x2 previews.
private struct LauncherMiniAppIcon: View {
    let app: LauncherApp
    @State private var icon: NSImage?
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 36, height: 36)
            .scaleEffect(isHovered ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)

            Text(app.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onAppear {
            if let cached = AppIconCache.shared.icon(for: app, completion: { icon = $0 }) {
                icon = cached
            }
        }
    }
}

/// SpringBoard-style full card modal detail view for a category.
struct LauncherCategoryDetailView: View {
    let category: AppCategory
    let apps: [LauncherApp]
    let onClose: () -> Void
    let onLaunch: (LauncherApp) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.4))
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }

            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: category.symbolName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.tint)

                    Text(category.rawValue)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("\(apps.count) apps")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 16)
                        ],
                        spacing: 16
                    ) {
                        ForEach(apps) { app in
                            LauncherCategoryAppCell(app: app)
                                .onTapGesture {
                                    onLaunch(app)
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 440)
            }
            .padding(24)
            .frame(maxWidth: 620)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.15 : 0.35), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.35), radius: 32, x: 0, y: 16)
        }
    }
}

private struct LauncherCategoryAppCell: View {
    let app: LauncherApp
    @State private var icon: NSImage?
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 52, height: 52)
            .scaleEffect(isHovered ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)

            Text(app.name)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 28, alignment: .top)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onAppear {
            if let cached = AppIconCache.shared.icon(for: app, completion: { icon = $0 }) {
                icon = cached
            }
        }
    }
}
