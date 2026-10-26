import AppKit
import XCTest
@testable import AnchorUtilities

final class QuickPanelWindowTests: XCTestCase {
    @MainActor private func fixture() -> UtilityPanelWindow {
        _ = NSApplication.shared
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 332, height: 430))
        let window = UtilityPanelWindow(contentViewController: controller)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        return window
    }

    @MainActor func testPanelKeepsItsLayerAndVisibilityWhenFocusLeaves() {
        let window = fixture()
        defer { window.close() }
        XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.mainMenu.rawValue + 3,
                             "The notch's transparent margins must not cover the title bar")
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isVisible)
        window.resignKey()
        XCTAssertTrue(window.isVisible)
        XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.mainMenu.rawValue + 3)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertFalse(window.becomesKeyOnlyIfNeeded)
    }

    @MainActor func testStandardCloseButtonAndReopenUseTheSameWindow() throws {
        let window = fixture()
        defer { window.close() }
        window.orderFront(nil)
        try XCTUnwrap(window.standardWindowButton(.closeButton)).performClick(nil)
        XCTAssertFalse(window.isVisible)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isVisible)
    }

    @MainActor func testEscapeAndCommandWCloseThePanel() throws {
        let window = fixture()
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        window.cancelOperation(nil)
        XCTAssertFalse(window.isVisible)
        window.makeKeyAndOrderFront(nil)
        let close = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "w", charactersIgnoringModifiers: "w",
            isARepeat: false, keyCode: 13))
        XCTAssertTrue(window.performKeyEquivalent(with: close))
        XCTAssertFalse(window.isVisible)
    }

    @MainActor func testPanelFitsTheCurrentDisplayIncludingItsTitleBar() throws {
        let window = fixture()
        defer { window.close() }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let available = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        window.setFrame(NSRect(x: available.maxX - 50, y: available.maxY - 50,
                               width: available.width + 200, height: available.height + 200),
                        display: false)
        window.constrainToScreen(screen)
        XCTAssertTrue(available.contains(window.frame))
        XCTAssertLessThan(window.maximumContentHeight(on: screen), available.height)
        XCTAssertEqual(window.maximumContentHeight(on: screen),
                       window.contentRect(forFrameRect: window.frame).height, accuracy: 0.5)
    }

    @MainActor func testEscapeDoesNotDismissAParentWithAnAttachedSheet() {
        let window = fixture()
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { window.endSheet(sheet); sheet.close(); window.close() }
        window.orderFront(nil)
        window.beginSheet(sheet)
        window.cancelOperation(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.attachedSheet === sheet)
    }
}
