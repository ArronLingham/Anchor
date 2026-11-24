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
import AnchorUtilities
import Defaults
import SwiftUI

/// Category library page: organizes all applications automatically into category tiles.
struct LauncherCategoryPageView: View {
    let widgetProfileID: String
    let appPageCount: Int
    let isPageActive: Bool
    let onOpenCategory: (AppCategory) -> Void
    let onLaunch: (LauncherApp) -> Void
    @ObservedObject private var index = AppIndex.shared

    private var activeCategories: [(category: AppCategory, apps: [LauncherApp])] {
        AppCategory.allCases.compactMap { cat in
            let catApps = index.apps(in: cat)
            return catApps.isEmpty ? nil : (category: cat, apps: catApps)
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 20) {
                LauncherWidgetShelf(
                    profileID: widgetProfileID,
                    page: LauncherPaging.categoriesPage,
                    appPageCount: appPageCount,
                    showCategories: true,
                    isPageActive: isPageActive
                )

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 14)],
                    spacing: 16
                ) {
                    ForEach(activeCategories, id: \.category.id) { item in
                        LauncherCategoryBoxView(
                            category: item.category,
                            apps: item.apps,
                            onOpenCategory: { onOpenCategory(item.category) },
                            onLaunch: onLaunch
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.never)
    }
}

/// A frosted card representing an application category with 2x2 preview icons.
struct LauncherCategoryBoxView: View {
    let category: AppCategory
    let apps: [LauncherApp]
    let onOpenCategory: () -> Void
    let onLaunch: (LauncherApp) -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = AnchorCorners.rectangle(cornerRadius: 18)
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpenCategory) {
                HStack(spacing: 7) {
                    Image(systemName: category.symbolName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AnchorDesign.muted)
                    Text(category.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AnchorDesign.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(apps.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(AnchorDesign.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(category.rawValue), \(apps.count) apps")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                ForEach(apps.prefix(4)) { app in
                    Button { onLaunch(app) } label: {
                        LauncherMiniAppIcon(app: app)
                            .frame(height: 54)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(app.name)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 144, alignment: .top)
        .padding(12)
        .background {
            shape.fill(AnchorDesign.surface.opacity(reduceTransparency ? 1 : isHovered ? 0.80 : 0.64))
                .overlay {
                    shape.anchorStrokeBorder(.white.opacity(contrast == .increased ? 0.5 : isHovered ? 0.22 : 0.12),
                                             lineWidth: 1)
                }
                .onTapGesture(perform: onOpenCategory)
                .accessibilityHidden(true)
        }
        .anchorCornerContainer(radius: 18)
        .onHover { isHovered = $0 }
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
                    AnchorCorners.rectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
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
                AnchorCorners.rectangle(cornerRadius: 24)
                    .fill(.regularMaterial)
                    .overlay(
                        AnchorCorners.rectangle(cornerRadius: 24)
                            .anchorStrokeBorder(Color.white.opacity(colorScheme == .dark ? 0.15 : 0.35), lineWidth: 1)
                    )
            )
            .anchorCornerContainer(radius: 24)
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
                    AnchorCorners.rectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.15))
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
            AnchorCorners.rectangle(cornerRadius: 12)
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
