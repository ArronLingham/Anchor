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

import SwiftUI
import UniformTypeIdentifiers

/// The shelf tab: drop files in, drag them back out.
struct NotchShelfView: View {
    @ObservedObject private var shelf = ShelfManager.shared
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            if shelf.items.isEmpty {
                empty
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTarget)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            load(providers)
            return true
        }
    }

    private var dropTarget: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                isTargeted ? Color.accentColor : Color.white.opacity(0.12),
                style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: shelf.items.isEmpty ? [6, 4] : []))
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
            Text("Drop files here")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text("They stay until you remove them")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private var grid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(shelf.items) { item in
                    tile(item)
                }
                Button {
                    shelf.clear()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 16))
                        Text("Clear").font(.system(size: 9))
                    }
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 56, height: 68)
                }
                .buttonStyle(.plain)
                .help("Remove everything from the shelf")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func tile(_ item: ShelfManager.Item) -> some View {
        VStack(spacing: 4) {
            Group {
                if let image = shelf.thumbnails[item.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08))
                }
            }
            .frame(width: 44, height: 44)

            Text(item.name)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 56)
        }
        .frame(width: 56, height: 68)
        .contentShape(Rectangle())
        // Dragging out hands over the real file, so a drop into Finder or any
        // app moves the original rather than a copy of a copy.
        .onDrag {
            guard let url = shelf.resolve(item) else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .onTapGesture(count: 2) { shelf.open(item) }
        .contextMenu {
            Button("Open") { shelf.open(item) }
            Button("Reveal in Finder") { shelf.revealInFinder(item) }
            Divider()
            Button("Remove", role: .destructive) { shelf.remove(item) }
        }
        .help(item.name)
    }

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in ShelfManager.shared.add(urls: [url]) }
            }
        }
    }
}
