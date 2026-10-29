"""Exercise the real Settings presentation and teardown methods with AppKit doubles."""
from pathlib import Path
import sys

source = (Path(__file__).resolve().parents[2] / 'Anchor/Components/Settings/SettingsWindowController.swift').read_text()

def extract(signature):
    start = source.index(signature)
    pos = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[pos] == '{') - (source[pos] == '}')
        pos += 1
    return source[start:pos]

present = extract('    private func presentWindow()')
close = extract('    private func relinquishFocus()')

support = r'''import Foundation
final class Content {}
final class MockWindow {
    struct Behavior: OptionSet {
        let rawValue: Int
        static let managed = Behavior(rawValue: 1)
        static let participatesInCycle = Behavior(rawValue: 2)
    }
    enum Level { case normal }
    var contentView: Content?
    var isVisible = false
    var isMiniaturized = false
    var level: Level = .normal
    var collectionBehavior: Behavior = []
    func deminiaturize(_ sender: Any?) { isMiniaturized = false }
    func orderFrontRegardless() { isVisible = true }
    func makeKeyAndOrderFront(_ sender: Any?) { isVisible = true }
    func center() {}
    func orderOut(_ sender: Any?) { isVisible = false }
}
final class MockApp { func activate(ignoringOtherApps: Bool) {} }
let NSApp = MockApp()
final class UtilityWorkspace {
    static let shared = UtilityWorkspace()
    var controlsVisible = false
}
final class AnchorApplicationPresentation {
    static let shared = AnchorApplicationPresentation()
    func register(_ window: MockWindow) {}
    func unregister(_ window: MockWindow) {}
}
final class Probe {
    var window: MockWindow? = MockWindow()
    var presentationGeneration = UUID()
    var contentInstalled = false
    var installs = 0
    func installContent() {
        installs += 1
        window?.contentView = Content()
        contentInstalled = true
    }
    func show() { presentWindow() }
    func close() { relinquishFocus() }
'''
checks = r'''
}
func flush() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
let probe = Probe()
probe.show()
precondition(probe.window!.isVisible && probe.contentInstalled && probe.installs == 1)
weak var first = probe.window!.contentView
probe.close()
flush()
precondition(!probe.window!.isVisible && !probe.contentInstalled && probe.window!.contentView == nil && first == nil,
             "closing must release the actual hosting content")
probe.show()
precondition(probe.installs == 2 && probe.window!.isVisible)
probe.close()
probe.show()
flush()
precondition(probe.window!.isVisible && probe.contentInstalled && probe.installs == 2,
             "a stale close cannot destroy a quickly reopened window")
probe.close()
flush()
probe.show()
probe.close()
flush()
precondition(!probe.window!.isVisible && !probe.contentInstalled,
             "a queued focus request cannot reopen a closed window")
print("Settings lifecycle: close releases content, reopen survives stale teardown, and stale focus cannot reopen it")
'''
Path(sys.argv[1]).write_text(support + present + '\n' + close + checks)
