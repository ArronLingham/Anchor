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

import Foundation
import SwiftUI
import Combine
import Defaults

// MARK: - Indicator Layout Enum
enum IndicatorLayout {
    case none
    case cameraOnly
    case microphoneOnly
    case cameraAndMicrophone
    case recordingOnly
    case recordingWithCamera
    case recordingWithMicrophone
    case recordingWithBoth
    
    // Computed properties for UI positioning
    var showsRecordingPulsator: Bool {
        switch self {
        case .recordingOnly, .recordingWithCamera, .recordingWithMicrophone, .recordingWithBoth:
            return true
        default:
            return false
        }
    }
    
    var showsCameraIndicator: Bool {
        switch self {
        case .cameraOnly, .cameraAndMicrophone, .recordingWithCamera, .recordingWithBoth:
            return true
        default:
            return false
        }
    }
    
    var showsMicrophoneIndicator: Bool {
        switch self {
        case .microphoneOnly, .cameraAndMicrophone, .recordingWithMicrophone, .recordingWithBoth:
            return true
        default:
            return false
        }
    }
    
    // Description for debugging
    var description: String {
        switch self {
        case .none: return "None"
        case .cameraOnly: return "Camera Only"
        case .microphoneOnly: return "Microphone Only"
        case .cameraAndMicrophone: return "Camera + Microphone"
        case .recordingOnly: return "Recording Only"
        case .recordingWithCamera: return "Recording + Camera"
        case .recordingWithMicrophone: return "Recording + Microphone"
        case .recordingWithBoth: return "Recording + Camera + Microphone"
        }
    }
}

// MARK: - Privacy Indicator Manager
@MainActor
class PrivacyIndicatorManager: ObservableObject {
    // MARK: - Singleton
    static let shared = PrivacyIndicatorManager()
    
    // MARK: - Published Properties
    @Published private(set) var microphoneActive: Bool = false
    @Published private(set) var screenRecordingActive: Bool = false
    @Published private(set) var isMonitoring: Bool = false
    
    // MARK: - Child Monitors
    private let microphoneMonitor = MicrophoneMonitor { Defaults[.enableMicrophoneDetection] }
    private var microphonePreference: AnyCancellable?
    
    // MARK: - Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Computed Properties
    
    /// Current indicator layout based on active states
    var indicatorLayout: IndicatorLayout {
        // Respect user settings
        let camera = false
        let mic = microphoneActive && Defaults[.enableMicrophoneDetection]
        let recording = screenRecordingActive
        
        // 8 possible combinations
        switch (recording, camera, mic) {
        case (false, false, false):
            return .none
        case (false, true, false):
            return .cameraOnly
        case (false, false, true):
            return .microphoneOnly
        case (false, true, true):
            return .cameraAndMicrophone
        case (true, false, false):
            return .recordingOnly
        case (true, true, false):
            return .recordingWithCamera
        case (true, false, true):
            return .recordingWithMicrophone
        case (true, true, true):
            return .recordingWithBoth
        }
    }
    
    /// Check if any indicator is active (respecting user settings)
    var hasAnyIndicator: Bool {
        let showCamera = false
        let showMic = microphoneActive && Defaults[.enableMicrophoneDetection]
        return showCamera || showMic || screenRecordingActive
    }
    
    private init() {
        // MicrophoneMonitor publishes on the main actor. Forward synchronously
        // so a queued value cannot restore an indicator after disablement.
        microphoneMonitor.$isMicActive
            .sink { [weak self] active in
                guard let self, self.microphoneActive != active else { return }
                withAnimation(.smooth) { self.microphoneActive = active }
            }
            .store(in: &cancellables)

        ScreenRecordingManager.shared.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording in
                guard let self, self.screenRecordingActive != recording else { return }
                withAnimation(.smooth) { self.screenRecordingActive = recording }
            }
            .store(in: &cancellables)
    }

    func startMonitoring() {
        guard microphonePreference == nil else { return }
        microphonePreference = Defaults.publisher(.enableMicrophoneDetection, options: [])
            .sink { [weak self] change in
                let enabled = change.newValue
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.syncMicrophone(enabled: enabled) }
                } else {
                    DispatchQueue.main.async { self?.syncMicrophone(enabled: enabled) }
                }
            }
        syncMicrophone(enabled: Defaults[.enableMicrophoneDetection])
    }

    func stopMonitoring() {
        microphonePreference = nil
        syncMicrophone(enabled: false)
    }

    private func syncMicrophone(enabled: Bool) {
        let wanted = enabled && microphonePreference != nil && Defaults[.enableMicrophoneDetection]
        if wanted { microphoneMonitor.startMonitoring() }
        else { microphoneMonitor.stopMonitoring() }
        if isMonitoring != wanted { isMonitoring = wanted }
    }
}
