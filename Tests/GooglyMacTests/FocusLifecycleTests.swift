import XCTest
import GooglyShared
@testable import GooglyMac

final class FocusLifecycleTests: XCTestCase {
    @MainActor func testPermissionFailureNeverCaptures() async {
        var captures = 0
        let app = FocusCompanion(now: { 100 }, permission: { false }, hasKey: { true },
            capture: { captures += 1; throw CancellationError() }, showsCountdown: false,
            historyFile: URL(fileURLWithPath: "/tmp/bluey-focus-test-permission.json"))
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
                showsCountdown: false, historyFile: URL(fileURLWithPath: "/tmp/bluey-focus-test-\(mode).json"))
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
            showsCountdown: false, historyFile: URL(fileURLWithPath: "/tmp/bluey-focus-test-cancel.json"))
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
