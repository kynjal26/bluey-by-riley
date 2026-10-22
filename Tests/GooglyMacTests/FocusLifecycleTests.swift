import XCTest
import GooglyShared
@testable import GooglyMac

final class FocusLifecycleTests: XCTestCase {
    @MainActor func testDeveloperCadenceSwitchingSpeedAndPause() async throws {
        var time = 100.0, captures = 0
        let observed = expectation(description: "First ten-second check")
        let answer = try FocusDecision.decode(Data(#"{"answers":[{"name":"activity","type":"choice","choice":"on_task","confidence":0.95,"probabilities":[{"value":"on_task","probability":0.95},{"value":"off_task","probability":0.02},{"value":"uncertain","probability":0.03}]}]}"#.utf8))
        let app = FocusCompanion(now: { time }, permission: { true }, hasKey: { true }, screenUnlocked: { true },
            capture: { captures += 1; return ScreenSnapshot(jpeg: Data(), lines: [], size: .zero) },
            classify: { _, _, _ in answer }, showsCountdown: false,
            historyFile: URL(fileURLWithPath: "/tmp/bluey-focus-test-developer.json"), settings: nil)
        app.onChange = { state in
            if state.current?.checks.contains(where: { $0.activity == .onTask }) == true {
                app.onChange = nil; observed.fulfill()
            }
        }
        app.setDeveloperMode(true); app.heartbeat(); _ = app.start(task: "Test clock")
        for _ in 1...9 { time += 1; app.heartbeat(); app.tick() }
        XCTAssertEqual(app.current?.elapsed, 36); XCTAssertEqual(captures, 0)
        time += 1; app.heartbeat(); app.tick()
        await fulfillment(of: [observed], timeout: 2)
        XCTAssertEqual(captures, 1); XCTAssertEqual(app.current?.checks.last?.sampleDuration, 40)
        XCTAssertEqual(app.current?.realActiveElapsed, 10)
        _ = app.pause(); time += 2; app.heartbeat(); app.tick()
        XCTAssertEqual(app.current?.elapsed, 40)
        app.setDeveloperMode(false); _ = app.resume()
        for _ in 1...29 { time += 1; app.heartbeat(); app.tick() }
        XCTAssertEqual(captures, 1); XCTAssertEqual(app.current?.elapsed, 69)
        time += 1; app.heartbeat(); app.tick(); await Task.yield()
        XCTAssertEqual(captures, 2); XCTAssertEqual(app.current?.elapsed, 70)
        _ = app.end()
    }
    @MainActor func testDeveloperSettingPersistsAndSwitchCancelsAnOldCapture() async {
        let name = "co.visionairy.googly.tests.\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        var time = 100.0
        var continuation: CheckedContinuation<ScreenSnapshot, Error>?
        let app = FocusCompanion(now: { time }, permission: { true }, hasKey: { true }, screenUnlocked: { true },
            capture: { try await withCheckedThrowingContinuation { continuation = $0 } },
            classify: { _, _, _ in XCTFail("Speed change must discard the old capture"); throw CancellationError() },
            showsCountdown: false, historyFile: URL(fileURLWithPath: "/tmp/bluey-focus-test-speed-change.json"), settings: preferences)
        XCTAssertFalse(app.developerMode)
        app.setDeveloperMode(true); app.heartbeat(); _ = app.start(task: "Cancel old check")
        for _ in 1...10 { time += 1; app.heartbeat(); app.tick() }
        await Task.yield(); XCTAssertNotNil(continuation)
        app.setDeveloperMode(false)
        continuation?.resume(returning: ScreenSnapshot(jpeg: Data(), lines: [], size: .zero))
        await Task.yield(); XCTAssertTrue(app.current?.checks.isEmpty == true)
        app.setDeveloperMode(true)
        let reopened = FocusCompanion(showsCountdown: false,
            historyFile: URL(fileURLWithPath: "/tmp/bluey-focus-test-reopened.json"), settings: preferences)
        XCTAssertTrue(reopened.developerMode)
        _ = app.end()
    }
    @MainActor func testPermissionFailureNeverCaptures() async {
        var captures = 0
        let app = FocusCompanion(now: { 100 }, permission: { false }, hasKey: { true },
            capture: { captures += 1; throw CancellationError() }, showsCountdown: false,
            historyFile: URL(fileURLWithPath: "/tmp/bluey-focus-test-permission.json"), settings: nil)
        app.heartbeat()
        XCTAssertTrue(app.start(task: "Write").contains("Screen Recording"))
        app.tick(); await Task.yield()
        XCTAssertNil(app.current); XCTAssertEqual(captures, 0)
    }
    @MainActor func testDisconnectLockAndPermissionLossPauseBeforeCapture() async {
        for mode in ["disconnect", "lock", "permission"] {
            var time = 100.0, permission = true, unlocked = true, captures = 0
            let app = FocusCompanion(now: { time }, permission: { permission }, hasKey: { true },
                screenUnlocked: { unlocked }, capture: { captures += 1; throw CancellationError() },
                showsCountdown: false, historyFile: URL(fileURLWithPath: "/tmp/bluey-focus-test-\(mode).json"), settings: nil)
            app.heartbeat(); _ = app.start(task: "Write")
            if mode == "disconnect" { time += 6 }
            if mode == "lock" { unlocked = false }
            if mode == "permission" { permission = false }
            app.tick(); await Task.yield()
            XCTAssertEqual(app.current?.status, .paused); XCTAssertEqual(captures, 0)
        }
    }
    @MainActor func testThirtySecondCadenceCancellationAndNoAutoResume() async {
        var time = 100.0, captures = 0
        var continuation: CheckedContinuation<ScreenSnapshot, Error>?
        let app = FocusCompanion(now: { time }, permission: { true }, hasKey: { true }, screenUnlocked: { true },
            capture: {
                captures += 1
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }, classify: { _, _, _ in XCTFail("Cancelled capture must not reach the API"); throw CancellationError() },
            showsCountdown: false, historyFile: URL(fileURLWithPath: "/tmp/bluey-focus-test-cancel.json"), settings: nil)
        app.heartbeat(); _ = app.start(task: "Write")
        for _ in 1...29 { time += 1; app.heartbeat(); app.tick() }
        XCTAssertEqual(captures, 0)
        time += 1; app.heartbeat(); app.tick()
        await Task.yield(); XCTAssertEqual(captures, 1)
        app.disconnected(); app.heartbeat(); app.tick()
        XCTAssertEqual(app.current?.status, .paused) // reconnection never resumes automatically
        continuation?.resume(returning: ScreenSnapshot(jpeg: Data(), lines: [], size: .zero))
        await Task.yield(); XCTAssertEqual(app.current?.checks.filter { $0.activity != .paused }.count, 0)
        _ = app.end()
    }
}
