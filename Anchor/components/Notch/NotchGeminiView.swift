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

/// The Gemini assistant tab.
///
/// Replies are rendered as **text**. They are never parsed for commands, never
/// matched against an action table and never executed — the model's output is
/// data here, which is what makes an assistant that reads arbitrary content
/// safe to have in a menu bar app.
struct NotchGeminiView: View {
    @ObservedObject private var manager = GeminiManager.shared
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
            Text("Add a Gemini API key in Settings › Gemini to use the assistant.")
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
                            Text(message.text)
                                .font(.system(size: 11))
                                .textSelection(.enabled)
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
            TextField("Ask Gemini\u{2026}", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .lineLimit(1...3)
                .focused($isComposerFocused)
                .onSubmit(send)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.08)))

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || manager.isSending)
        }
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await manager.send(text) }
    }
}
