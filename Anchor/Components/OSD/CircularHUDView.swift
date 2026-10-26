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

#if os(macOS)
import SwiftUI
import Defaults
import CoreAudio

struct CircularHUDView: View {
    @Binding var type: SneakContentType
    @Binding var value: CGFloat
    @Binding var icon: String
    var screen: NSScreen?
    var isPreview = false
    
    @Default(.circularHUDShowValue) var showValue
    @Default(.circularHUDSize) var size
    @Default(.circularHUDStrokeWidth) var strokeWidth
    @Default(.circularHUDUseAccentColor) var useAccentColor
    
    @Environment(\.colorScheme) var colorScheme
    
    @Default(.useColorCodedVolumeDisplay) var useColorCodedVolume
    @Default(.useSmoothColorGradient) var useSmoothGradient
    
    var body: some View {
        Group {
        let layout = CircularHUDLayout(diameter: size, stroke: strokeWidth)
        let level = CircularHUDLayout.normalized(value)
        let knob = layout.knobOffset(value: level)
        ZStack {
            Circle().fill(LinearGradient(colors: [AnchorDesign.raised, AnchorDesign.inset], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().strokeBorder(AnchorDesign.edge, lineWidth: 1))
            Circle().trim(from: 0.15, to: 0.85)
                .stroke(Color(white: 0.18), style: StrokeStyle(lineWidth: layout.stroke * 1.5, lineCap: .round))
                .rotationEffect(.degrees(90))
            Circle().trim(from: 0.15, to: 0.15 + 0.7 * level)
                .stroke(strokeStyle, style: StrokeStyle(lineWidth: layout.stroke * 1.5, lineCap: .round))
                .rotationEffect(.degrees(90))
                .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.85), value: level)
            Circle().fill(.white)
                .frame(width: layout.stroke * 2.175, height: layout.stroke * 2.175)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .offset(x: knob.x, y: knob.y)
                .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.85), value: level)
            VStack(spacing: layout.diameter * 0.045) {
                Image(systemName: symbolName)
                    .font(.system(size: layout.diameter * (showValue ? 0.27 : 0.32), weight: .semibold))
                    .symbolRenderingMode(.hierarchical).foregroundStyle(.white)
                    .frame(width: layout.diameter * 0.52, height: layout.diameter * 0.32, alignment: .center)
                if showValue {
                    HUDNumericLabel(value: level,
                        font: .system(size: layout.diameter * 0.15, weight: .semibold, design: .rounded),
                        color: .white.opacity(0.75), width: layout.diameter * 0.6, showsPercentSign: true)
                        .frame(height: layout.diameter * 0.19)
                }
            }.frame(width: layout.diameter * 0.65, height: layout.diameter * 0.65, alignment: .center)
        }
        .frame(width: layout.diameter, height: layout.diameter)
        .hudDragToSet(type: isPreview ? .music : type, axis: .horizontal, screen: screen)
        .frame(width: layout.diameter, height: layout.diameter)
        .shadow(color: .black.opacity(0.2), radius: 15, y: 5)
        .frame(width: layout.canvasSize, height: layout.canvasSize, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(type == .volume ? "Volume" : "Brightness")
        .accessibilityValue(CircularHUDLayout.percentage(level) + " percent")
            }
        .anchorTheme()
    }

    private var strokeStyle: AnyShapeStyle {
        if type == .volume && useColorCodedVolume {
            return ColorCodedProgressBar.shapeStyle(for: value, mode: .volume, smoothGradient: useSmoothGradient)
        }
        
        if useAccentColor {
            return AnyShapeStyle(Color.accentColor)
        }
        
        // Default to the approved solid dark gray to match reference when not colored
        return AnyShapeStyle(AnchorDesign.accent)
    }
    
    private var symbolName: String {
        if !icon.isEmpty { return icon }
        
        switch type {
        case .volume:
            // Check if headphones/AirPods are connected
            let deviceInfo = getAudioDeviceInfo()
            
            if deviceInfo.isAirPods {
                // Use AirPods icon when AirPods are connected
                if value < 0.01 { return "headphones.slash" }
                else { return "airpods" }
            } else if deviceInfo.isHeadphones {
                // Use headphone icons when other headphones are connected
                if value < 0.01 { return "headphones.slash" }
                else { return "headphones" }
            } else {
                // Use speaker icons for built-in speakers
                if value < 0.01 { return "speaker.slash.fill" }
                else if value < 0.33 { return "speaker.wave.1.fill" }
                else if value < 0.66 { return "speaker.wave.2.fill" }
                else { return "speaker.wave.3.fill" }
            }
        case .brightness:
            return "sun.max.fill"
        case .contrast:
            return "circle.lefthalf.filled"
        case .backlight:
            return "keyboard"
        default:
            return "questionmark"
        }
    }
    
    private struct AudioDeviceInfo {
        let isAirPods: Bool
        let isHeadphones: Bool
    }
    
    private func getAudioDeviceInfo() -> AudioDeviceInfo {
        #if os(macOS)
        // Get default output device
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout.size(ofValue: deviceID))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return AudioDeviceInfo(isAirPods: false, isHeadphones: false)
        }
        
        // Get device name.
        //
        // CoreAudio writes a +1-retained CFStringRef into this buffer, so it
        // has to be an Unmanaged reference: pointing a raw pointer at a plain
        // `CFString` var and letting the framework overwrite it is forming a
        // pointer to an object reference, which the compiler warns about and
        // which leaks the returned string.
        var deviceName: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &deviceName) == noErr,
              let cfName = deviceName?.takeRetainedValue()
        else {
            return AudioDeviceInfo(isAirPods: false, isHeadphones: false)
        }

        let name = (cfName as String).lowercased()
        
        // Check for AirPods specifically
        let isAirPods = name.contains("airpod")
        
        // Check for other headphones
        let isHeadphones = name.contains("headphone") || 
                          name.contains("ear") ||
                          name.contains("buds") ||
                          name.contains("beats")
        
        return AudioDeviceInfo(isAirPods: isAirPods, isHeadphones: !isAirPods && isHeadphones)
        #else
        return AudioDeviceInfo(isAirPods: false, isHeadphones: false)
        #endif
    }
}
#endif
