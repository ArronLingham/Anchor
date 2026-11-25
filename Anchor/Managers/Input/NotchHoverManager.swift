import AppKit
import Combine
import Defaults
import SwiftUI

/// Tracks the "extend hover area" band above each display's pill.
///
/// It publishes the **set of display names** the pointer is currently extending
/// into, not one global `Bool`. `ContentView` is instantiated once per screen,
/// so a single shared flag meant hovering the band on one display called
/// `handleHover(true)` on every display and opened the notch on all of them at
/// once — the pointer is only ever over one screen. The geometry itself lives in
/// `NotchHoverGeometry`, which is pure and pinned by
/// `tests/run_externalpill_tests.sh`.
@MainActor
final class NotchHoverManager: ObservableObject {
    static let shared = NotchHoverManager()

    /// Localized names of the displays whose hover band contains the pointer.
    @Published private(set) var hoveredScreenNames: Set<String> = []

    private var moveMonitor: Any?
    private var flagsMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var islandVisible = false
    private var monitorGeneration = UUID()

    private var currentModifiers: NSEvent.ModifierFlags = []

    private init() {}

    /// Whether the pointer is in the extended band of the named display.
    ///
    /// `screenName` is nil only before a view model has resolved its screen; a
    /// view that does not know which display it is on must not claim the hover.
    func isHoveringExtendedArea(on screenName: String?) -> Bool {
        guard let screenName else { return false }
        return hoveredScreenNames.contains(screenName)
    }

    func start() {
        guard !started else { return }
        started = true

        let keys: [Defaults.Key<Bool>] = [.openNotchOnHover, .extendHoverArea, .enableDynamicIsland]
        for key in keys {
            Defaults.publisher(key, options: [])
                .receive(on: DispatchQueue.main)
                .sink { [weak self] change in
                    guard let self, self.started else { return }
                    if !change.newValue { self.remove() }
                    self.sync()
                }
                .store(in: &cancellables)
        }

        sync()
    }

    func setIslandVisible(_ visible: Bool) {
        guard islandVisible != visible else { return }
        islandVisible = visible
        sync()
    }

    func stop() {
        started = false
        cancellables.removeAll()
        remove()
    }

    private var shouldMonitor: Bool {
        started && islandVisible && Defaults[.enableDynamicIsland]
            && Defaults[.openNotchOnHover] && Defaults[.extendHoverArea]
    }

    private func sync() {
        if shouldMonitor {
            install()
        } else {
            remove()
        }
    }

    private func install() {
        let generation = monitorGeneration
        if moveMonitor == nil {
            currentModifiers = NSEvent.modifierFlags
            moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.accepts(generation) else { return }
                    self.pointerMoved(to: NSEvent.mouseLocation)
                }
            }
        }

        if flagsMonitor == nil {
            flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.accepts(generation) else { return }
                    self.currentModifiers = event.modifierFlags
                }
            }
        }
    }

    private func accepts(_ generation: UUID) -> Bool {
        monitorGeneration == generation && shouldMonitor
    }

    private func remove() {
        monitorGeneration = UUID()
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        moveMonitor = nil
        flagsMonitor = nil
        currentModifiers = []
        publish([])
    }

    private func pointerMoved(to point: NSPoint) {
        guard currentModifiers.intersection([.command, .option, .control, .shift]).isEmpty else {
            publish([])
            return
        }

        let hovered = NotchHoverGeometry.hoveredDisplayNames(
            point: point,
            displays: currentDisplays()
        )
        publish(hovered)
    }

    /// The displays to test, each carrying **its own** closed pill size.
    ///
    /// The size comes from that screen's live view model when one exists, and
    /// from `getClosedNotchSize(screen:)` otherwise. It used to come from
    /// `AppDelegate.shared.vm.closedNotchSize` — the singleton view model, which
    /// in multi-window mode drives no window at all and is sized for
    /// `NSScreen.main`, so an external display's band was the width of the
    /// built-in's physical notch.
    ///
    /// A display whose notch is already open is left out rather than reported,
    /// so a hover cannot re-trigger against an open notch. That guard is
    /// per-screen too: the other display's notch being open is not this
    /// display's business.
    private func currentDisplays() -> [NotchHoverGeometry.Display] {
        let delegate = AppDelegate.shared
        return NSScreen.screens.compactMap { screen in
            let name = screen.localizedName
            let viewModel = delegate?.viewModels[screen]
            let resolved = viewModel ?? (delegate?.vm.screen == name ? delegate?.vm : nil)
            if let resolved, resolved.notchState != .closed { return nil }
            return NotchHoverGeometry.Display(
                name: name,
                frame: screen.frame,
                closedNotchSize: resolved?.closedNotchSize ?? getClosedNotchSize(screen: name)
            )
        }
    }

    private func publish(_ hovered: Set<String>) {
        guard hoveredScreenNames != hovered else { return }
        hoveredScreenNames = hovered
    }
}
