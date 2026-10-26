import XCTest
@testable import AnchorUtilities

/// Runs upstream's behavioral inputs against the integrated production module.
/// Assertions are collected so one failure does not hide the rest of a workflow.
final class TestSuite {
    private(set) var checks = 0
    private(set) var failures: [String] = []

    func expect(_ value: Bool, _ message: @autoclosure () -> String,
                file: StaticString = #filePath, line: UInt = #line) {
        checks += 1
        if !value { failures.append("\(file):\(line): \(message())") }
    }

    func expectClose(_ actual: Double, _ expected: Double, _ label: String,
                     tol: Double = 0.0001, file: StaticString = #filePath, line: UInt = #line) {
        expect(actual.isFinite && expected.isFinite && tol.isFinite && tol >= 0 && abs(actual - expected) <= tol,
               "\(label): got \(actual), expected \(expected)", file: file, line: line)
    }
}

final class NativeBehaviorTests: XCTestCase {
    private func verify(_ body: (TestSuite) -> Void) {
        let suite = TestSuite()
        body(suite)
        XCTAssertGreaterThan(suite.checks, 0)
        for failure in suite.failures { XCTFail(failure) }
        print("Native utility behaviors: \(suite.checks) checks, \(suite.failures.count) failures")
    }
    func testMediaConversionAndOriginalPreservation() { verify(MediaFeatureTests.run) }
    func testMetricsFormattingAndSamplingPolicy() { verify(MetricsFeatureTests.run) }
    func testAudioDevicePriorityAndFallbacks() { verify(AudioPriorityTests.run) }
    func testCapsuleSizingAndSymbolAlignment() { verify(NotchCapsuleTests.run) }
    func testCompanionAnimationAndGeometry() { verify(NotchMascotTests.run) }
    func testWindowFocusHistory() {
        verify { suite in WindowFocusHistoryTests.run { suite.expect($0, $1) } }
    }
    func testRecordingExportWithSyntheticAudioCutsBlurAndGIF() {
        verify(RecorderExportRenderingTests.run)
    }
}
