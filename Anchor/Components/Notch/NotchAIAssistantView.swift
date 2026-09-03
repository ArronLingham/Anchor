/*

 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import SwiftUI
import ScreenCaptureKit
import CoreGraphics

struct NotchAIAssistantView: View {
    @ObservedObject private var manager = AIAssistantManager.shared
    @State private var draft = ""
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if !manager.hasAPIKey {
                missingKey
            } else {
                transcript
                composer
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var missingKey: some View {
        VStack(spacing: 6) {
            Image(systemName: "key")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            Text("Add an API key in Settings › Gemini to use the assistant.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Settings") { SettingsWindowController.shared.showWindow() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(manager.messages) { message in
                        HStack {
                            if message.role == .user { Spacer(minLength: 40) }
                            VStack(alignment: message.role == .user ? .trailing : .leading) {
                                if let img = message.imageData, let nsImg = NSImage(data: img) {
                                    Image(nsImage: nsImg)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 150)
                                        .cornerRadius(6)
                                }
                                if !message.text.isEmpty {
                                    Text(message.text)
                                        .font(.system(size: 11))
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(message.role == .user
                                          ? Color.accentColor.opacity(0.28)
                                          : Color.white.opacity(0.10)))
                            .foregroundStyle(.white)
                            if message.role == .model { Spacer(minLength: 40) }
                        }
                        .id(message.id)
                    }
                    if manager.isSending {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Thinking\u{2026}")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    if let error = manager.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: manager.messages.count) { _, _ in
                guard let last = manager.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 6) {
            Button(action: sendWithScreenshot) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(manager.isSending)
            .help("Send Screen")

            TextField("Ask AI\u{2026}", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .lineLimit(1...3)
                .focused($isComposerFocused)
                .onSubmit(sendText)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.08)))

            Button(action: sendText) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || manager.isSending)
        }
    }

    private func captureScreen() async -> Data? {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let bitmap = NSBitmapImageRep(cgImage: image)
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
        } catch {
            return nil
        }
    }

    private func sendWithScreenshot() {
        let text = draft
        draft = ""
        Task {
            let img = await captureScreen()
            await manager.send(text, screenshot: img)
        }
    }

    private func sendText() {
        let text = draft
        draft = ""
        Task { await manager.send(text) }
    }
}
