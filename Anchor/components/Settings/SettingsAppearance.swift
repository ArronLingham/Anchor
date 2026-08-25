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

struct Appearance: View {
    @ObservedObject var coordinator = AnchorViewCoordinator.shared
    @Default(.sliderColor) var sliderColor
    @Default(.useMusicVisualizer) var useMusicVisualizer
    @Default(.customVisualizers) var customVisualizers
    @Default(.selectedVisualizer) var selectedVisualizer
    @Default(.customAppIcons) private var customAppIcons
    @Default(.selectedAppIconID) private var selectedAppIconID
    @Default(.openNotchWidth) var openNotchWidth
    @Default(.closedNotchWidth) var closedNotchWidth
    @Default(.customizePhysicalNotchWidth) var customizePhysicalNotchWidth
    @Default(.enableMinimalisticUI) var enableMinimalisticUI
    @Default(.lockScreenGlassCustomizationMode) private var lockScreenGlassCustomizationMode
    @Default(.lockScreenGlassStyle) private var lockScreenGlassStyle
    @Default(.lockScreenMusicLiquidGlassVariant) private var lockScreenMusicLiquidGlassVariant
    @Default(.lockScreenTimerLiquidGlassVariant) private var lockScreenTimerLiquidGlassVariant
    @Default(.lockScreenTimerGlassStyle) private var lockScreenTimerGlassStyle
    @Default(.lockScreenTimerGlassCustomizationMode) private var lockScreenTimerGlassCustomizationMode
    @Default(.lockScreenTimerWidgetUsesBlur) private var timerGlassModeIsGlass
    @Default(.enableLockScreenMediaWidget) private var enableLockScreenMediaWidget
    @Default(.enableLockScreenTimerWidget) private var enableLockScreenTimerWidget
    @Default(.externalDisplayStyle) private var externalDisplayStyle
    @State private var selectedListVisualizer: CustomVisualizer? = nil

    @State private var isIconImporterPresented = false
    @State private var isIconDropTarget = false
    @State private var iconImportError: String?

    @State private var isPresented: Bool = false
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var speed: CGFloat = 1.0

    /// Whether the main screen has a physical notch.
    private var mainScreenHasPhysicalNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.safeAreaInsets.top > 0
    }

    private var notchWidthRange: ClosedRange<Double> {
        let minW = Double(currentRecommendedMinimumNotchWidth())
        let maxW = min(900, Double(maxAllowedNotchWidth()))
        return minW...max(minW, maxW)
    }
    private var defaultOpenNotchWidth: CGFloat {
        currentRecommendedMinimumNotchWidth()
    }

    private func highlightID(_ title: String) -> String {
        SettingsTab.appearance.highlightID(for: title)
    }

    private var liquidVariantRange: ClosedRange<Double> {
        Double(LiquidGlassVariant.supportedRange.lowerBound)...Double(LiquidGlassVariant.supportedRange.upperBound)
    }

    private var appearanceMusicVariantBinding: Binding<Double> {
        Binding(
            get: { Double(lockScreenMusicLiquidGlassVariant.rawValue) },
            set: { newValue in
                let raw = Int(newValue.rounded())
                lockScreenMusicLiquidGlassVariant = LiquidGlassVariant.clamped(raw)
            }
        )
    }

    private var appearanceTimerVariantBinding: Binding<Double> {
        Binding(
            get: { Double(lockScreenTimerLiquidGlassVariant.rawValue) },
            set: { newValue in
                let raw = Int(newValue.rounded())
                lockScreenTimerLiquidGlassVariant = LiquidGlassVariant.clamped(raw)
            }
        )
    }

    private var timerSurfaceBinding: Binding<LockScreenTimerSurfaceMode> {
        Binding(
            get: { timerGlassModeIsGlass ? .glass : .classic },
            set: { mode in timerGlassModeIsGlass = (mode == .glass) }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Always show tabs", isOn: $coordinator.alwaysShowTabs)
                Defaults.Toggle(key: .settingsIconInNotch) {
                    Text("Settings icon in notch")
                }
                .settingsHighlight(id: highlightID("Settings icon in notch"))
                Defaults.Toggle(key: .enableShadow) {
                    Text("Enable window shadow")
                }
                .settingsHighlight(id: highlightID("Enable window shadow"))
                Defaults.Toggle(key: .cornerRadiusScaling) {
                    Text("Corner radius scaling")
                }
                .settingsHighlight(id: highlightID("Corner radius scaling"))
                Defaults.Toggle(key: .useModernCloseAnimation) {
                    Text("Use simpler close animation")
                }
                .settingsHighlight(id: highlightID("Use simpler close animation"))
            } header: {
                Text("General")
            }

            // Show display style picker only on non-notch Macs (main screen has no physical notch)
            if !mainScreenHasPhysicalNotch {
                Section {
                    Picker("Main screen style", selection: $externalDisplayStyle) {
                        ForEach(ExternalDisplayStyle.allCases) { style in
                            Text(style.localizedName)
                                .tag(style)
                        }
                    }
                    .onChange(of: externalDisplayStyle) {
                        NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                    }
                    .settingsHighlight(id: highlightID("Main screen style"))
                    Text(externalDisplayStyle.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Display Style")
                }
            }

            notchWidthControls()

            Section {
                if #available(macOS 26.0, *) {
                    Picker("Material", selection: $lockScreenGlassStyle) {
                        ForEach(LockScreenGlassStyle.allCases) { style in
                            Text(style.localizedName).tag(style)
                        }
                    }
                    .settingsHighlight(id: highlightID("Lock screen material"))
                } else {
                    Picker("Material", selection: $lockScreenGlassStyle) {
                        ForEach(LockScreenGlassStyle.allCases) { style in
                            Text(style.localizedName).tag(style)
                        }
                    }
                    .disabled(true)
                    .settingsHighlight(id: highlightID("Lock screen material"))
                    Text("Liquid Glass requires macOS 26 or later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if lockScreenGlassStyle == .liquid {
                    Picker("Lock screen glass mode", selection: $lockScreenGlassCustomizationMode) {
                        ForEach(LockScreenGlassCustomizationMode.allCases) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .settingsHighlight(id: highlightID("Lock screen glass mode"))

                    if lockScreenGlassCustomizationMode == .customLiquid {
                        Text("Pick per-widget liquid-glass variants below. Changes mirror the Lock Screen tab.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Music panel variant")
                                Spacer()
                                Text("v\(lockScreenMusicLiquidGlassVariant.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: appearanceMusicVariantBinding, in: liquidVariantRange, step: 1)

                            LockScreenGlassVariantPreviewCell(variant: $lockScreenMusicLiquidGlassVariant)
                                .padding(.top, 6)
                        }
                        .settingsHighlight(id: highlightID("Music panel variant (appearance)"))
                        .disabled(!enableLockScreenMediaWidget)
                        .opacity(enableLockScreenMediaWidget ? 1 : 0.4)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Timer widget variant")
                                Spacer()
                                Text("v\(lockScreenTimerLiquidGlassVariant.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: appearanceTimerVariantBinding, in: liquidVariantRange, step: 1)
                        }
                        .settingsHighlight(id: highlightID("Timer widget variant (appearance)"))
                        .disabled(!enableLockScreenTimerWidget)
                        .opacity(enableLockScreenTimerWidget ? 1 : 0.4)
                    }
                } else {
                    Text("Custom Liquid settings require the Liquid Glass material.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Lock Screen Glass")
            } footer: {
                Text("Configure lock screen materials from the Appearance tab. Custom Liquid unlocks variant sliders for both widgets whenever Liquid Glass is selected.")
            }

            Section {
                Defaults.Toggle(key: .coloredSpectrogram) {
                    Text("Enable colored spectrograms")
                }
                .settingsHighlight(id: highlightID("Enable colored spectrograms"))
                Defaults.Toggle(key: .playerColorTinting) {
                    Text("Enable colored spectograms")
                }
                Defaults.Toggle(key: .lightingEffect) {
                    Text("Enable blur effect behind album art")
                }
                .settingsHighlight(id: highlightID("Enable blur effect behind album art"))
                Picker("Slider color", selection: $sliderColor) {
                    ForEach(SliderColorEnum.allCases, id: \.self) { option in
                        Text(option.localizedName)
                    }
                }
                .settingsHighlight(id: highlightID("Slider color"))
            } header: {
                Text("Media")
            }

            Section {
                Toggle(
                    "Use music visualizer spectrogram",
                    isOn: $useMusicVisualizer.animation()
                )
                .disabled(true)
                if !useMusicVisualizer {
                    if customVisualizers.count > 0 {
                        Picker(
                            "Selected animation",
                            selection: $selectedVisualizer
                        ) {
                            ForEach(
                                customVisualizers,
                                id: \.self
                            ) { visualizer in
                                Text(visualizer.name)
                                    .tag(visualizer)
                            }
                        }
                    } else {
                        HStack {
                            Text("Selected animation")
                            Spacer()
                            Text("No custom animation available")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Custom music live activity animation")
                    customBadge(text: "Coming soon")
                }
            }

            Section {
                List {
                    ForEach(customVisualizers, id: \.self) { visualizer in
                        HStack {
                            LottieView(state: LUStateData(type: .loadedFrom(visualizer.url), speed: visualizer.speed, loopMode: .loop))
                                .frame(width: 30, height: 30, alignment: .center)
                            Text(visualizer.name)
                            Spacer(minLength: 0)
                            if selectedVisualizer == visualizer {
                                Text("selected")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                    .padding(.trailing, 8)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.vertical, 2)
                        .background(
                            selectedListVisualizer != nil ? selectedListVisualizer == visualizer ? Color.accentColor : Color.clear : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedListVisualizer == visualizer {
                                selectedListVisualizer = nil
                                return
                            }
                            selectedListVisualizer = visualizer
                        }
                    }
                }
                .safeAreaPadding(
                    EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0)
                )
                .frame(minHeight: 120)
                .actionBar {
                    HStack(spacing: 5) {
                        Button {
                            name = ""
                            url = ""
                            speed = 1.0
                            isPresented.toggle()
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                        }
                        Divider()
                        Button {
                            if selectedListVisualizer != nil {
                                let visualizer = selectedListVisualizer!
                                selectedListVisualizer = nil
                                customVisualizers.remove(at: customVisualizers.firstIndex(of: visualizer)!)
                                if visualizer == selectedVisualizer && customVisualizers.count > 0 {
                                    selectedVisualizer = customVisualizers[0]
                                }
                            }
                        } label: {
                            Image(systemName: "minus")
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                        }
                    }
                }
                .controlSize(.small)
                .buttonStyle(PlainButtonStyle())
                .overlay {
                    if customVisualizers.isEmpty {
                        Text("No custom visualizer")
                            .foregroundStyle(Color(.secondaryLabelColor))
                            .padding(.bottom, 22)
                    }
                }
                .sheet(isPresented: $isPresented) {
                    VStack(alignment: .leading) {
                        Text("Add new visualizer")
                            .font(.largeTitle.bold())
                            .padding(.vertical)
                        TextField("Name", text: $name)
                        TextField("Lottie JSON URL", text: $url)
                        HStack {
                            Text("Speed")
                            Spacer(minLength: 80)
                            Text("\(speed, specifier: "%.1f")s")
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                            Slider(value: $speed, in: 0...2, step: 0.1)
                        }
                        .padding(.vertical)
                        HStack {
                            Button {
                                isPresented.toggle()
                            } label: {
                                Text("Cancel")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }

                            Button {
                                let visualizer: CustomVisualizer = .init(
                                    UUID: UUID(),
                                    name: name,
                                    url: URL(string: url)!,
                                    speed: speed
                                )

                                if !customVisualizers.contains(visualizer) {
                                    customVisualizers.append(visualizer)
                                }

                                isPresented.toggle()
                            } label: {
                                Text("Add")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                            .buttonStyle(BorderedProminentButtonStyle())
                        }
                    }
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .controlSize(.extraLarge)
                    .padding()
                }
            } header: {
                HStack(spacing: 0) {
                    Text("Custom vizualizers (Lottie)")
                    if !Defaults[.customVisualizers].isEmpty {
                        Text(" – \(Defaults[.customVisualizers].count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Defaults.Toggle(key: .showNotHumanFace) {
                    Text("Idle Animation")
                }
                .settingsHighlight(id: highlightID("Idle Animation"))
            } header: {
                HStack {
                    Text("Additional features")
                }
            }

            // MARK: - Custom Idle Animations Section
            IdleAnimationsSettingsSection()

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    let columns = [GridItem(.adaptive(minimum: 90), spacing: 12)]
                    LazyVGrid(columns: columns, spacing: 12) {
                        appIconCard(
                            title: "Default",
                            image: defaultAppIconImage(),
                            isSelected: selectedAppIconID == nil
                        ) {
                            selectedAppIconID = nil
                            applySelectedAppIcon()
                        }

                        ForEach(customAppIcons) { icon in
                            appIconCard(
                                title: icon.name,
                                image: customIconImage(for: icon),
                                isSelected: selectedAppIconID == icon.id.uuidString
                            ) {
                                selectedAppIconID = icon.id.uuidString
                                applySelectedAppIcon()
                            }
                            .contextMenu {
                                Button("Remove") {
                                    removeCustomIcon(icon)
                                }
                            }
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(isIconDropTarget ? 0.18 : 0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(isIconDropTarget ? 0.8 : 0), lineWidth: 2)
                    )
                    .onDrop(of: [UTType.fileURL], isTargeted: $isIconDropTarget) { providers in
                        handleIconDrop(providers)
                    }

                    HStack(spacing: 8) {
                        Button("Add icon") {
                            iconImportError = nil
                            isIconImporterPresented = true
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Remove selected") {
                            if let id = selectedAppIconID,
                               let icon = customAppIcons.first(where: { $0.id.uuidString == id }) {
                                removeCustomIcon(icon)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedAppIconID == nil)
                    }

                    if let iconImportError {
                        Text(iconImportError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Drop a PNG, JPEG, TIFF, or ICNS file to add it to your icon library.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .settingsHighlight(id: highlightID("App icon"))
            } header: {
                HStack {
                    Text("App icon")
                }
            }
        }
        .onAppear(perform: enforceLockScreenGlassConsistency)
        .onChange(of: lockScreenGlassStyle) { _, _ in enforceLockScreenGlassConsistency() }
        .onChange(of: lockScreenGlassCustomizationMode) { _, _ in enforceLockScreenGlassConsistency() }
        .fileImporter(
            isPresented: $isIconImporterPresented,
            allowedContentTypes: [.png, .jpeg, .tiff, .icns, .image]
        ) { result in
            switch result {
            case .success(let url):
                importCustomIcon(from: url)
            case .failure:
                iconImportError = "Icon import was canceled or failed."
            }
        }
        .navigationTitle("Appearance")
    }

    private func defaultAppIconImage() -> NSImage? {
        let fallbackName = Bundle.main.iconFileName ?? "AppIcon"
        return NSImage(named: fallbackName)
    }

    private func customIconImage(for icon: CustomAppIcon) -> NSImage? {
        NSImage(contentsOf: icon.fileURL)
    }

    private func appIconCard(title: String, image: NSImage?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                )

                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(isSelected ? Color.accentColor : .clear)
                    )
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func handleIconDrop(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.first { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard let provider = matching else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let directURL = item as? URL {
                url = directURL
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = nil
            }
            guard let url else { return }
            Task { @MainActor in importCustomIcon(from: url) }
        }
        return true
    }

    private func importCustomIcon(from url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            iconImportError = "That file could not be loaded as an image."
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let id = UUID()
        let fileName = "custom-icon-\(id.uuidString).\(ext)"
        let destination = CustomAppIcon.iconDirectory.appendingPathComponent(fileName)

        do {
            let data = try Data(contentsOf: url)
            try data.write(to: destination, options: [.atomic])
        } catch {
            iconImportError = "Unable to save the icon file."
            return
        }

        let newIcon = CustomAppIcon(id: id, name: name.isEmpty ? "Custom Icon" : name, fileName: fileName)
        if !customAppIcons.contains(newIcon) {
            customAppIcons.append(newIcon)
        }
        selectedAppIconID = newIcon.id.uuidString
        NSApp.applicationIconImage = image
        iconImportError = nil
    }

    private func removeCustomIcon(_ icon: CustomAppIcon) {
        if let index = customAppIcons.firstIndex(of: icon) {
            customAppIcons.remove(at: index)
        }
        if FileManager.default.fileExists(atPath: icon.fileURL.path) {
            try? FileManager.default.removeItem(at: icon.fileURL)
        }
        if selectedAppIconID == icon.id.uuidString {
            selectedAppIconID = nil
            applySelectedAppIcon()
        }
    }

    func checkVideoInput() -> Bool {
        if let _ = AVCaptureDevice.default(for: .video) {
            return true
        }

        return false
    }

    @ViewBuilder
    private func notchWidthControls() -> some View {
        Section {
            let recommendedMin = currentRecommendedMinimumNotchWidth()
            let tabCount = enabledStandardTabCount()
            let dynamicRange = Double(recommendedMin)...900
            
            let closedRange = Double(80)...400
            let minimalisticRange = Double(250)...600

            let widthBinding = Binding<Double>(
                get: { Double(openNotchWidth) },
                set: { newValue in
                    let clamped = min(max(newValue, dynamicRange.lowerBound), dynamicRange.upperBound)
                    let value = CGFloat(clamped)
                    if openNotchWidth != value {
                        openNotchWidth = value
                    }
                }
            )
            
            let closedWidthBinding = Binding<Double>(
                get: { Double(closedNotchWidth) },
                set: { newValue in
                    let clamped = min(max(newValue, closedRange.lowerBound), closedRange.upperBound)
                    let value = CGFloat(clamped)
                    if closedNotchWidth != value {
                        closedNotchWidth = value
                        NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
            )

            VStack(alignment: .leading, spacing: 10) {
                Defaults.Toggle(key: .customizePhysicalNotchWidth) {
                    Text("Customize physical notch width")
                }
                .onChange(of: customizePhysicalNotchWidth) {
                    NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                }
                .settingsHighlight(id: highlightID("Customize physical notch width"))
                
                Slider(
                    value: closedWidthBinding,
                    in: closedRange,
                    step: 5
                ) {
                    HStack {
                        Text("Closed notch / pill width")
                        Spacer()
                        Text("\(Int(closedNotchWidth)) px")
                            .foregroundStyle(.secondary)
                    }
                }
                .settingsHighlight(id: highlightID("Closed notch / pill width"))

                Divider().padding(.vertical, 4)

                Slider(
                    value: widthBinding,
                    in: dynamicRange,
                    step: 10
                ) {
                    HStack {
                        Text("Expanded notch width")
                        Spacer()
                        Text("\(Int(openNotchWidth)) px")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(enableMinimalisticUI)
                .settingsHighlight(id: highlightID("Expanded notch width"))

                HStack {
                    Text("\(tabCount) tab\(tabCount == 1 ? "" : "s") enabled · min \(Int(recommendedMin)) px")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Width") {
                        openNotchWidth = recommendedMin
                    }
                    .disabled(abs(openNotchWidth - recommendedMin) < 0.5)
                    .buttonStyle(.bordered)
                }

                let description = enableMinimalisticUI
                ? String(localized: "Expanded width adjustments apply only to the standard notch layout. Disable Minimalistic UI to edit this value.")
                : String(localized: "Recommended minimum width adjusts automatically based on the number of enabled tabs.")

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                enforceMinimumNotchWidth()
            }
        } header: {
            HStack {
                Text("Notch Width")
                customBadge(text: "Beta")
            }
        }
    }

    private func enforceLockScreenGlassConsistency() {
        if lockScreenGlassStyle == .frosted && lockScreenGlassCustomizationMode != .standard {
            lockScreenGlassCustomizationMode = .standard
        }
        if lockScreenGlassCustomizationMode == .customLiquid && lockScreenGlassStyle != .liquid {
            lockScreenGlassStyle = .liquid
        }
    }
}

private struct LockScreenGlassVariantPreviewCell: View {
    @Binding var variant: LiquidGlassVariant

    private let cornerRadius: CGFloat = 16
    private let previewCornerRadius: CGFloat = 14
    private let previewSize = CGSize(width: 190, height: 96)

    var body: some View {
        ZStack {
            Image("glassdesktop")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            liquidGlassPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.vertical, 6)
        .allowsHitTesting(false)
        .onAppear {
            Logger.log("Lock screen glass preview appeared (variant v\(variant.rawValue))", category: .performance)
        }
        .onDisappear {
            Logger.log("Lock screen glass preview disappeared", category: .performance)
        }
        .onChange(of: variant) { _, newValue in
            Logger.log("Lock screen glass preview variant changed to v\(newValue.rawValue)", category: .performance)
        }
    }

    private var liquidGlassPreview: some View {
        LiquidGlassBackground(
            variant: variant,
            cornerRadius: previewCornerRadius
        ) {
            Color.white.opacity(0.04)
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
    }
}
