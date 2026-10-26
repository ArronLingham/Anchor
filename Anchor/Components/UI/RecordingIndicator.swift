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

struct RecordingIndicator: View {
    @ObservedObject var recordingManager = ScreenRecordingManager.shared
    
    // MARK: - Configuration
    private let indicatorSize: CGFloat = 6
    private let glowSize: CGFloat = 2
    
    var body: some View {
        Group {
            if recordingManager.isRecording {
                ZStack {
                    // Glow effect
                    Circle()
                        .fill(Color.red.opacity(0.3))
                        .frame(width: indicatorSize + glowSize * 2, height: indicatorSize + glowSize * 2)
                        .blur(radius: glowSize)
                    
                    // Main indicator dot
                    Circle()
                        .fill(Color.red)
                        .frame(width: indicatorSize, height: indicatorSize)
                }
                .transition(.asymmetric(
                    insertion: .scale.combined(with: .opacity),
                    removal: .scale.combined(with: .opacity)
                ))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: recordingManager.isRecording)
    }
    

}

// MARK: - Preview

struct RecordingIndicator_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // Recording state preview
            VStack {
                Text("Recording Active")
                    .font(.caption)
                RecordingIndicator()
                    .onAppear {
                        ScreenRecordingManager.shared.isRecording = true
                    }
            }
            .padding()
            .background(Color.black)
            .previewDisplayName("Recording Active")
            
            // Non-recording state preview
            VStack {
                Text("Not Recording")
                    .font(.caption)
                RecordingIndicator()
                    .onAppear {
                        ScreenRecordingManager.shared.isRecording = false
                    }
            }
            .padding()
            .background(Color.black)
            .previewDisplayName("Not Recording")
        }
    }
}

// MARK: - Alternative Indicator Styles

struct RecordingIndicatorLarge: View {
    @ObservedObject var recordingManager = ScreenRecordingManager.shared
    
    private let indicatorSize: CGFloat = 10
    private let glowSize: CGFloat = 3
    
    var body: some View {
        Group {
            if recordingManager.isRecording {
                ZStack {
                    // Outer glow
                    Circle()
                        .fill(Color.red.opacity(0.2))
                        .frame(width: indicatorSize + glowSize * 4, height: indicatorSize + glowSize * 4)
                        .blur(radius: glowSize)
                    
                    // Inner glow
                    Circle()
                        .fill(Color.red.opacity(0.4))
                        .frame(width: indicatorSize + glowSize * 2, height: indicatorSize + glowSize * 2)
                        .blur(radius: glowSize / 2)
                    
                    // Main indicator
                    Circle()
                        .fill(Color.red)
                        .frame(width: indicatorSize, height: indicatorSize)
                }
                .transition(.asymmetric(
                    insertion: .scale.combined(with: .opacity),
                    removal: .scale.combined(with: .opacity)
                ))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: recordingManager.isRecording)
    }
}

// MARK: - Subtle Indicator for Closed State

struct RecordingIndicatorSubtle: View {
    @ObservedObject var recordingManager = ScreenRecordingManager.shared
    
    var body: some View {
        Group {
            if recordingManager.isRecording {
                Circle()
                    .fill(Color.red)
                    .frame(width: 4, height: 4)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: recordingManager.isRecording)
    }
}