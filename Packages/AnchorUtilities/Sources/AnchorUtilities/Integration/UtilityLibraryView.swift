import SwiftUI

/// A compact entry point shared by Anchor Settings and the Dashboard. The
/// detailed editors keep the same destination map as search and Command Bar.
public struct UtilityLibraryView: View {
    @ObservedObject private var workspace = UtilityWorkspace.shared
    @State private var query = ""
    @State private var favoritesOnly = false
    @State private var stateFilter = "All"
    private let showsTitle: Bool

    public init(showsTitle: Bool = true) { self.showsTitle = showsTitle }

    private func matching(_ all: [UtilityFeature]) -> [UtilityFeature] {
        all.filter { feature in
            (!favoritesOnly || workspace.favorites.contains(feature.id)) &&
                (stateFilter == "All" || (stateFilter == "Enabled") == feature.isEnabled) &&
                (query.isEmpty || "\(feature.title) \(feature.summary) \(feature.group)"
                    .localizedStandardContains(query))
        }
    }

    public var body: some View {
        let all = workspace.features
        let matching = matching(all)
        let groups = all.reduce(into: [String]()) { groups, item in
            if !groups.contains(item.group), matching.contains(where: { $0.group == item.group }) {
                groups.append(item.group)
            }
        }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        if showsTitle { Text("Features & Tools").font(.title2.bold()) }
                        Text("Enable the features you use. Turning one off stops its background work and releases loaded windows and caches.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Quick Panel") { workspace.showPanel() }
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search features and controls", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("AnchorFeatureSearch")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).help("Clear search")
                    }
                    Toggle("Favorites", isOn: $favoritesOnly).toggleStyle(.button)
                }
                .padding(10).background(.quaternary.opacity(0.5), in: AnchorCorners.rectangle(cornerRadius: 10))
                HStack {
                    Text("\(all.filter(\.isEnabled).count) enabled").font(.caption).foregroundStyle(.secondary)
                    Picker("Show features", selection: $stateFilter) {
                        Text("All").tag("All")
                        Text("Enabled").tag("Enabled")
                        Text("Disabled").tag("Disabled")
                    }.pickerStyle(.segmented).frame(maxWidth: 280)
                    Spacer()
                    Button("Disable all") { workspace.disableAllFeatures() }
                        .disabled(!all.contains(where: \.isEnabled))
                        .accessibilityIdentifier("AnchorDisableAllFeatures")
                }
                if let notice = workspace.featureNotice {
                    HStack(alignment: .top) {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss") { workspace.clearFeatureNotice() }.font(.caption)
                    }
                }
                if workspace.needsRestartToUnload {
                    HStack {
                        Text("Some shared memory can be released with a restart. Your setup is saved.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Anchor") { workspace.restartToReleaseMemory() }.font(.caption)
                    }
                }
                HStack {
                    Label(workspace.commandBarShortcutHint, systemImage: "command")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Tool settings & permissions…") { workspace.showControls() }
                        .help("Opens tool settings in this same Anchor Settings window.")
                        .font(.caption)
                }
            }.padding(22)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(groups, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group).font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 12)], spacing: 12) {
                                ForEach(matching.filter { $0.group == group }) { feature in
                                    featureCard(feature)
                                }
                            }
                        }
                    }
                    if matching.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity).padding(.vertical, 45)
                    }
                }.padding(22)
            }
        }
        .onReceive(workspace.$featureToEnable) { id in
            guard let id, let feature = workspace.features.first(where: { $0.id == id }) else { return }
            stateFilter = "All"
            favoritesOnly = false
            query = feature.title
            workspace.consumeFeatureReveal(id)
        }
    }

    private func featureCard(_ feature: UtilityFeature) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                Label(feature.title, systemImage: feature.symbol)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Button { workspace.toggleFavorite(feature.id) } label: {
                    Image(systemName: workspace.favorites.contains(feature.id) ? "star.fill" : "star")
                        .foregroundStyle(workspace.favorites.contains(feature.id) ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .help(workspace.favorites.contains(feature.id) ? "Remove from favorites" : "Add to Dashboard favorites")
                .accessibilityLabel("Favorite \(feature.title)")
            }
            Text(feature.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(3).frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
            HStack {
                Toggle(feature.isEnabled ? "Enabled" : "Disabled", isOn: Binding(
                    get: { feature.isEnabled },
                    set: { workspace.setEnabled(feature.id, $0) }))
                    .toggleStyle(.switch).controlSize(.small)
                    .disabled(!feature.isSupported && !feature.isEnabled)
                    .accessibilityLabel("Enable \(feature.title)")
                    .accessibilityIdentifier("AnchorFeatureToggle." + feature.id)
                Spacer(minLength: 4)
                if feature.isEnabled {
                    Button(feature.canRun ? "Open" : "Configure") {
                        feature.canRun ? workspace.run(feature.id) : workspace.showFeature(feature.id)
                    }.buttonStyle(.bordered)
                } else if !feature.isSupported {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
            }
            .help(feature.unsupportedReason ?? feature.summary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: AnchorCorners.rectangle(cornerRadius: 12))
        .overlay { AnchorCorners.rectangle(cornerRadius: 12).anchorStrokeBorder(.quaternary, lineWidth: 1) }
    }
}

public struct UtilityFavoritesView: View {
    @ObservedObject private var workspace = UtilityWorkspace.shared
    public init() {}

    public var body: some View {
        let byID = Dictionary(uniqueKeysWithValues: workspace.features.map { ($0.id, $0) })
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 8)], spacing: 8) {
                ForEach(workspace.favorites.compactMap { byID[$0] }) { feature in
                    Button {
                        if feature.isEnabled { workspace.run(feature.id) }
                        else { workspace.revealFeature(feature.id) }
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: feature.symbol).font(.system(size: 18))
                            Text(feature.title).font(.system(size: 11)).lineLimit(2)
                            if !feature.isEnabled { Text("Disabled").font(.system(size: 9)).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .buttonStyle(.borderless)
                    .background(.quaternary.opacity(0.4), in: AnchorCorners.rectangle(cornerRadius: 9))
                    .help(feature.isEnabled ? feature.summary : "Enable this feature in Features & Tools")
                    .contextMenu {
                        Button(feature.isEnabled ? "Disable feature" : "Enable feature") {
                            workspace.setEnabled(feature.id, !feature.isEnabled)
                        }
                        Button("Configure") { workspace.showFeature(feature.id) }
                        Button("Remove from favorites") { workspace.toggleFavorite(feature.id) }
                    }
                }
            }
            Button("Browse all features…") { workspace.showLibrary() }.font(.system(size: 12))
        }
    }
}
