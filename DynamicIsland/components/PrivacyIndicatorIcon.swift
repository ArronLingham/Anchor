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

import SwiftUI

// MARK: - Privacy Indicator Type
enum PrivacyIndicatorType {
    case camera
    case microphone
    
    var icon: String {
        switch self {
        case .camera:
            return "video.fill"
        case .microphone:
            return "mic.fill"
        }
    }
    
    var label: String {
        switch self {
        case .camera:
            return "Camera Active"
        case .microphone:
            return "Microphone Active"
        }
    }
    
    var accessibilityLabel: String {
        switch self {
        case .camera:
            return "Camera is being used by an application"
        case .microphone:
            return "Microphone is being used by an application"
        }
    }
}

// MARK: - Privacy Indicator Icon View
struct PrivacyIndicatorIcon: View {
    // MARK: - Properties
    let type: PrivacyIndicatorType
    let showLabel: Bool
    
    @State private var isAnimating: Bool = false
    
    // MARK: - Initialization
    init(type: PrivacyIndicatorType, showLabel: Bool = false) {
        self.type = type
        self.showLabel = showLabel
    }
    
    // MARK: - Body
    var body: some View {
        HStack(spacing: 4) {
            // Icon with glow effect
            ZStack {
                // Background glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.orange.opacity(0.4),
                                Color.orange.opacity(0.2),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 12
                        )
                    )
                    .frame(width: 24, height: 24)
                    .opacity(isAnimating ? 0.8 : 0.5)
                
                // Icon background circle
                Circle()
                    .fill(Color.orange.opacity(0.2))
                    .frame(width: 18, height: 18)
                
                // Icon
                Image(systemName: type.icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
            }
            .frame(width: 24, height: 24)
            
            // Optional label
            if showLabel {
                Text(type.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))
            }
        }
        .accessibilityLabel(type.accessibilityLabel)
        .onAppear {
            startPulseAnimation()
        }
    }
    
    // MARK: - Animation
    private func startPulseAnimation() {
        withAnimation(
            .easeInOut(duration: 1.5)
            .repeatForever(autoreverses: true)
        ) {
            isAnimating = true
        }
    }
}

// MARK: - Privacy Indicator Container
/// Container view that shows both camera and microphone indicators based on layout

// MARK: - Privacy Indicator Detail View
/// Detailed view showing privacy indicator status (for settings/tips)

// MARK: - Preview
#Preview("Single Indicators") {
    VStack(spacing: 20) {
        PrivacyIndicatorIcon(type: .camera)
        PrivacyIndicatorIcon(type: .microphone)
        PrivacyIndicatorIcon(type: .camera, showLabel: true)
        PrivacyIndicatorIcon(type: .microphone, showLabel: true)
    }
    .padding()
    .background(Color.black)
}
