"""Run current production focus methods against a deterministic AppKit model.
No real activation, typing, pasteboard access, or synthetic key events occur.
The model includes Apple's documented makeFirstResponder(true) fallback.
"""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[2]
def extract(path, signature):
    source=(root/path).read_text()
    start=source.index(signature)
    brace=source.index('{',start)
    end,depth=brace+1,1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[start:end]
launcher=extract('Anchor/Managers/Launcher/LauncherPanelManager.swift','    func hide(restoringFocus:')
clipboard=extract('Anchor/Managers/Clipboard/ClipboardPanelManager.swift','    private func presentPanel()')
terminal=extract('Anchor/Managers/Productivity/TerminalManager.swift','    private func focusTerminalIfPossible(attemptsRemaining:')
focus=extract('Packages/AnchorUtilities/Sources/AnchorUtilities/Services/CommandBar/CommandBarService.swift','    private func focusField(in ')
field=extract('Packages/AnchorUtilities/Sources/AnchorUtilities/Services/CommandBar/CommandBarService.swift','    private static func editableField(in ')
view=(root/'Anchor/Components/Launcher/LauncherView.swift').read_text()
manager=(root/'Anchor/Managers/Launcher/LauncherPanelManager.swift').read_text()
assert 'onDismiss()\n            result.command.run()' in view
assert 'panel.onResignKey = { [weak self] in self?.hide() }' in manager
support='''import Foundation
var destination = "none"
var reproductions = 0
func confirm(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("Could not reproduce: " + message) }
    reproductions += 1
    print("REPRODUCED: " + message)
}
class NSView {
    var window: NSWindow?
    var isHidden = false
    var subviews: [NSView] = []
    func layoutSubtreeIfNeeded() {}
}
class NSTextField: NSView { var isEditable = true; var isEnabled = true }
class NSTextView: NSView { var isFieldEditor = true }
class NSWindow {
    let name: String
    var firstResponder: AnyObject?
    var contentView: NSView? = NSTextField()
    var isKeyWindow = false
    var acceptsRequestedResponder = true
    init(_ name: String) { self.name = name }
    func makeKey() { destination = name; isKeyWindow = true }
    func makeKeyAndOrderFront(_ sender: Any?) { makeKey() }
    func orderFrontRegardless() {}
    func makeFirstResponder(_ responder: NSView?) -> Bool {
        if !acceptsRequestedResponder {
            // Documented AppKit behavior: the window becomes first responder,
            // and true is returned even though the requested view refused it.
            firstResponder = self
            return true
        }
        firstResponder = responder is NSTextField ? NSTextView() : responder
        return true
    }
}
final class Application {
    var isActive = false
    func activate(ignoringOtherApps: Bool) { isActive = true }
}
let NSApp = Application()
final class RunningApp {
    let bundleIdentifier: String?
    init(_ name: String) { bundleIdentifier = name }
    func activate() { destination = bundleIdentifier! }
}
final class LauncherPanel: NSWindow {
    var onResignKey: (() -> Void)?
    var completion: (() -> Void)?
    func dismiss(_ completion: @escaping () -> Void) { self.completion = completion }
    func finishAnimation() { completion?(); completion = nil }
}
final class ClipboardPanel: NSWindow {
    init() { super.init("Clipboard") }
    func positionNearNotch() {}
}
'''
classes='\nfinal class LauncherProbe { var panel: LauncherPanel?; var previouslyActiveApp: RunningApp?\n'+launcher+'\n}\n'
classes+='final class ClipboardProbe { var clipboardPanel: ClipboardPanel?\nfunc hideClipboardPanel() { clipboardPanel = nil }\nfunc show() { presentPanel() }\n'+clipboard+'\n}\n'
classes+='final class TerminalProbe { var terminalView: NSView? = NSView(); let containerView = NSView()\nfunc show() { focusTerminalIfPossible(attemptsRemaining: 3) }\n'+terminal+'\n}\n'
classes+='final class CommandFocusProbe { func claim(_ window: NSWindow) -> Bool { focusField(in: window) }\n'+focus+'\n'+field+'\n}\n'
tests='''
func launcherSession() -> (LauncherProbe, LauncherPanel) {
    let manager = LauncherProbe(), panel = LauncherPanel("Launchpad")
    manager.panel = panel; manager.previouslyActiveApp = RunningApp("Finder")
    return (manager,panel)
}
do {
    let (manager,panel) = launcherSession()
    manager.hide()
    panel.finishAnimation()
    precondition(destination == "Finder") // Control: Escape should restore.
    print("CONTROL: explicit dismissal restores the previous app")
}
do {
    let (manager,panel) = launcherSession()
    destination = "Dashboard field"
    manager.hide() // Exact callback wired by onResignKey.
    panel.finishAnimation()
    confirm(destination == "Finder", "Launchpad resignation overrides a newly selected Dashboard field")
}
do {
    let (manager,panel) = launcherSession()
    manager.hide() // LauncherView calls onDismiss BEFORE command.run.
    destination = "Command destination"
    panel.finishAnimation()
    confirm(destination == "Finder", "Launchpad command completion overrides the command's destination")
}
do {
    let (manager,panel) = launcherSession()
    manager.hide()
    manager.panel = LauncherPanel("New presentation")
    manager.previouslyActiveApp = RunningApp("Dashboard")
    destination = "New presentation"
    panel.finishAnimation()
    confirm(destination == "Finder", "an old dismissal completion overrides a newer presentation")
}
do {
    let manager = ClipboardProbe()
    manager.show()
    destination = "Dashboard field"
    RunLoop.main.run(until: Date().addingTimeInterval(0.16))
    confirm(destination == "Clipboard", "clipboard's delayed key request overrides a later field click")
}
do {
    let manager = TerminalProbe()
    manager.show() // Terminal has not mounted in a window yet.
    manager.containerView.window = NSWindow("Terminal")
    destination = "Dashboard field"
    RunLoop.main.run(until: Date().addingTimeInterval(0.16))
    confirm(destination == "Terminal", "a terminal mount retry overrides a later field click")
}
do {
    let window = NSWindow("Command bar")
    window.acceptsRequestedResponder = false
    let accepted = CommandFocusProbe().claim(window)
    confirm(accepted && window.firstResponder === window,
            "command-bar focus helper reports success when AppKit falls back to the window")
}
print("\\(reproductions) existing focus failure cases reproduced; these are NOT passing fix regressions.")
'''
Path(sys.argv[1]).write_text(support+classes+tests)
