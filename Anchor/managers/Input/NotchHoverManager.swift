import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class NotchHoverManager: ObservableObject {
    static let shared = NotchHoverManager()

    @Published var isHoveringExtendedArea: Bool = false

    private var moveMonitor: Any?
    private var flagsMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private var currentModifiers: NSEvent.ModifierFlags = []

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        Defaults.publisher(.openNotchOnHover)
            .sink { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
            .store(in: &cancellables)
            
        Defaults.publisher(.extendHoverArea)
            .sink { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
            .store(in: &cancellables)

        sync()
    }

    private func sync() {
        (Defaults[.openNotchOnHover] && Defaults[.extendHoverArea]) ? install() : remove()
    }

    private func install() {
        guard moveMonitor == nil else { return }

        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved(to: NSEvent.mouseLocation) }
        }
        
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.currentModifiers = event.modifierFlags
            }
        }
    }

    private func remove() {
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        moveMonitor = nil
        flagsMonitor = nil
        isHoveringExtendedArea = false
    }

    private func pointerMoved(to point: NSPoint) {
        guard currentModifiers.intersection([.command, .option, .control, .shift]).isEmpty else {
            isHoveringExtendedArea = false
            return
        }

        guard let delegate = AppDelegate.shared else { return }
        guard delegate.vm.notchState == .closed else {
            isHoveringExtendedArea = false
            return
        }
        
        var isInside = false
        for screen in NSScreen.screens {
            let notchRect = calculateExtendedNotchRect(for: screen, vm: delegate.vm)
            if notchRect.contains(point) {
                isInside = true
                break
            }
        }

        if isHoveringExtendedArea != isInside {
            isHoveringExtendedArea = isInside
        }
    }

    private func calculateExtendedNotchRect(for screen: NSScreen, vm: AnchorViewModel) -> NSRect {
        let closedSize = vm.closedNotchSize
        let extensionHeight = CGFloat(12)
        
        let screenFrame = screen.frame
        let width = closedSize.width + 40
        let height = closedSize.height + extensionHeight
        
        let x = screenFrame.midX - (width / 2)
        let y = screenFrame.maxY - height
        
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
