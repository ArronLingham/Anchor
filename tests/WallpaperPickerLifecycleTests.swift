import Foundation

final class PanelInteractionState {
    static let shared = PanelInteractionState()
    var isPresentingPopoverModal = false
}

final class TestPanel {
    enum Response { case OK, cancelled }
    let urls = [URL(fileURLWithPath: "/tmp/fixture-wallpaper.jpg")]
    var completion: ((Response) -> Void)?
    private(set) var cancelled = false
    func begin(completion: @escaping (Response) -> Void) { self.completion = completion }
    func cancel(_ sender: Any?) { cancelled = true }
}

final class PickerFixture {
    var openPanel: TestPanel?
    var isAvailable = true
}

@main
enum WallpaperPickerLifecycleTests {
    static func main() {
        let fixture = PickerFixture()
        let oldPanel = TestPanel()
        let newPanel = TestPanel()
        var picked: [URL] = []
        fixture.present(oldPanel) { picked = $0 }
        precondition(PanelInteractionState.shared.isPresentingPopoverModal)
        fixture.isAvailable = false
        fixture.closeOpenPanel()
        precondition(oldPanel.cancelled && fixture.openPanel == nil)
        precondition(!PanelInteractionState.shared.isPresentingPopoverModal)

        fixture.isAvailable = true
        fixture.present(newPanel) { picked = $0 }
        oldPanel.completion?(.OK)
        precondition(picked.isEmpty && fixture.openPanel === newPanel)
        precondition(PanelInteractionState.shared.isPresentingPopoverModal)
        newPanel.completion?(.OK)
        precondition(picked == newPanel.urls && fixture.openPanel == nil)
        precondition(!PanelInteractionState.shared.isPresentingPopoverModal)

        picked = []
        fixture.present(newPanel) { picked = $0 }
        fixture.isAvailable = false
        newPanel.completion?(.OK)
        precondition(picked.isEmpty && fixture.openPanel == nil)
        print("Wallpaper picker cancellation and stale completion checks passed")
    }
}
