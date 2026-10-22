import XCTest
import CryptoKit
@testable import GooglyShared

final class FocusTests: XCTestCase {
    func testDeveloperClockRunsFourTimesFasterAndPauseStillFreezesIt() {
        var session = FocusSession(task: "Test Bluey", duration: 60, developerMode: true)
        session.advance(1)
        XCTAssertEqual(session.elapsed, 4); XCTAssertEqual(session.realActiveElapsed, 1)
        XCTAssertEqual(session.checkInterval, 10); XCTAssertEqual(session.observationDuration, 40)
        session.pause("Testing"); session.advance(100)
        XCTAssertEqual(session.elapsed, 4); XCTAssertEqual(session.realActiveElapsed, 1)
        session.resume(); session.advance(20)
        XCTAssertEqual(session.status, .ended); XCTAssertEqual(session.elapsed, 60)
        XCTAssertEqual(session.realActiveElapsed, 15) // expiry clamps both clocks
    }
    func testChangingSpeedPreservesBothClocksAndMarksTestHistory() throws {
        var session = FocusSession(task: "Test speed changes")
        session.advance(10); session.setDeveloperMode(true); session.advance(10)
        XCTAssertEqual(session.elapsed, 50); XCTAssertEqual(session.realActiveElapsed, 20)
        session.setDeveloperMode(false); session.advance(10)
        XCTAssertEqual(session.elapsed, 60); XCTAssertEqual(session.realActiveElapsed, 30)
        XCTAssertEqual(session.usedDeveloperMode, true); XCTAssertEqual(session.clockRate, 1)
        let sync = FocusSync(current: session, history: [session], revision: 3, developerMode: true)
        let copy = try JSONDecoder().decode(FocusSync.self, from: JSONEncoder().encode(sync))
        XCTAssertEqual(copy.developerMode, true); XCTAssertEqual(copy.current, session)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        for key in ["developerMode", "usedDeveloperMode", "realElapsed"] { old.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(FocusSession.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertFalse(legacy.isDeveloperMode); XCTAssertEqual(legacy.clockRate, 1)
        XCTAssertEqual(legacy.realActiveElapsed, legacy.elapsed)
    }
    func testDeveloperObservationsUseAcceleratedNudgeTimeAndStillReset() {
        var policy = FocusNudgePolicy(maximumGap: 60)
        for t in [40.0, 80, 120, 160] { XCTAssertFalse(policy.observe(off(t), age: 1)) }
        XCTAssertTrue(policy.observe(off(200), age: 1)) // fifth check at 50 real seconds
        XCTAssertFalse(policy.observe(off(240), age: 21)) // stale uses real seconds
        for t in [280.0, 320, 360, 400] { XCTAssertFalse(policy.observe(off(t), age: 1)) }
        XCTAssertTrue(policy.observe(off(440), age: 1))
        var gap = FocusNudgePolicy(maximumGap: 60)
        for t in [40.0, 80, 120, 160] { _ = gap.observe(off(t), age: 1) }
        XCTAssertFalse(gap.observe(off(240), age: 1)) // missing ten-second check resets evidence
    }
    func testVoiceRetainsBeginningUntilConnectedAndRejectsEmptyTurns() {
        var turn = VoiceTurnBuffer()
        XCTAssertFalse(turn.canCommit)
        let beginning = Data(repeating: 1, count: 4800)
        XCTAssertNil(turn.append(beginning, ready: false))
        XCTAssertTrue(turn.canCommit)
        XCTAssertEqual(turn.connected(), [beginning])
        XCTAssertTrue(turn.connected().isEmpty)
        let next = Data(repeating: 2, count: 4800)
        XCTAssertEqual(turn.append(next, ready: true), next)
        turn.begin(); XCTAssertFalse(turn.canCommit)
        XCTAssertNil(turn.append(Data(repeating: 0, count: 960_001), ready: false))
        XCTAssertTrue(turn.overflowed); XCTAssertFalse(turn.canCommit)
    }
    func off(_ elapsed: Double, _ strength: Double = 0.99) -> FocusCheck {
        FocusCheck(elapsed: elapsed, activity: .offTask, probability: strength, confidence: strength)
    }
    func testTwoMinuteMinimumAndCooldown() {
        var policy = FocusNudgePolicy()
        for t in stride(from: 30.0, through: 120, by: 30) { XCTAssertFalse(policy.observe(off(t), age: 1)) }
        XCTAssertTrue(policy.observe(off(150), age: 1))
        for t in stride(from: 180.0, through: 270, by: 30) { XCTAssertFalse(policy.observe(off(t), age: 1)) }
        XCTAssertTrue(policy.observe(off(300), age: 1))
    }
    func testModerateEvidenceWaitsThreeToFourMinutes() {
        var policy = FocusNudgePolicy()
        for t in stride(from: 0.0, through: 180, by: 30) { XCTAssertFalse(policy.observe(off(t, 0.65), age: 2)) }
        XCTAssertTrue(policy.observe(off(210, 0.65), age: 2))
        var weak = FocusNudgePolicy()
        for t in stride(from: 0.0, through: 210, by: 30) { XCTAssertFalse(weak.observe(off(t, 0.5), age: 1)) }
        XCTAssertTrue(weak.observe(off(240, 0.5), age: 1))
    }
    func testOnTaskUncertainUnavailableAndPauseResetEvidence() {
        for activity in [FocusActivity.onTask, .uncertain, .unavailable, .paused] {
            var policy = FocusNudgePolicy()
            for t in [0.0, 30, 60, 90] { XCTAssertFalse(policy.observe(off(t), age: 1)) }
            XCTAssertFalse(policy.observe(FocusCheck(elapsed: 120, activity: activity), age: 1))
            for t in [150.0, 180, 210, 240] { XCTAssertFalse(policy.observe(off(t), age: 1)) }
            XCTAssertTrue(policy.observe(off(270), age: 1))
        }
    }
    func testStaleGapAndLowConfidenceDoNotAccumulate() {
        var policy = FocusNudgePolicy()
        for t in [0.0, 30, 60, 90] { _ = policy.observe(off(t), age: 1) }
        XCTAssertFalse(policy.observe(off(120), age: 21))
        XCTAssertFalse(policy.observe(off(150), age: 1))
        XCTAssertFalse(policy.observe(off(240), age: 1)) // missing checks reset the span
        var low = off(270); low.confidence = 0.49
        XCTAssertFalse(policy.observe(low, age: 1))
        XCTAssertFalse(policy.observe(off(300), age: 1))
        XCTAssertFalse(policy.observe(off(330), age: -1))
        XCTAssertFalse(policy.observe(off(.nan), age: 1))
    }
    func testPauseResumeExpiryAndSynchronizationRoundTrip() throws {
        var session = FocusSession(task: "Make a Codex video", duration: 60)
        session.advance(30); session.pause("Locked")
        session.advance(900); XCTAssertEqual(session.elapsed, 30)
        session.resume(); session.advance(31)
        XCTAssertEqual(session.elapsed, 60); XCTAssertEqual(session.status, .ended)
        session.advance(500); XCTAssertEqual(session.elapsed, 60)
        let sync = FocusSync(current: session, history: [session], revision: 9)
        let decoded = try JSONDecoder().decode(FocusSync.self, from: JSONEncoder().encode(sync))
        XCTAssertEqual(decoded.current, session); XCTAssertEqual(decoded.revision, 9)
        XCTAssertEqual(FocusSession(task: "x").duration, 1800)
    }
    func testChoiceContractAndMalformedRefusal() throws {
        let good = Data(#"{"answers":[{"type":"choice","name":"activity","choice":"off_task","confidence":0.7,"probabilities":[{"value":"on_task","probability":0.1},{"value":"off_task","probability":0.8},{"value":"uncertain","probability":0.1}]}]}"#.utf8)
        let result = try FocusDecision.decode(good)
        XCTAssertEqual(result.probability, 0.8); XCTAssertEqual(result.confidence, 0.7)
        XCTAssertEqual(result.probabilities, ["on_task": 0.1, "off_task": 0.8, "uncertain": 0.1])
        for bad in [#"{"answers":[{"type":"refusal","name":"activity"}]}"#, "{}", String(data: good, encoding: .utf8)!.replacingOccurrences(of: "0.8", with: "1.8")] {
            XCTAssertThrowsError(try FocusDecision.decode(Data(bad.utf8)))
        }
    }
    func testChoiceEstimatesSurviveSyncAndOlderHistoryDoesNotInventValues() throws {
        let check = FocusCheck(elapsed: 30, activity: .onTask, probability: 0.15, confidence: 0.73,
                               probabilities: ["on_task": 0.65, "off_task": 0.15, "uncertain": 0.2])
        var session = FocusSession(task: "Make a video")
        session.checks = [check]
        let sync = FocusSync(current: session, history: [session], revision: 10)
        let decoded = try JSONDecoder().decode(FocusSync.self, from: JSONEncoder().encode(sync))
        XCTAssertEqual(decoded.current?.checks.first, check)
        XCTAssertEqual(check.estimate(for: .onTask), 0.65)
        XCTAssertEqual(check.estimate(for: .uncertain), 0.2)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(check)) as? [String: Any])
        old.removeValue(forKey: "probabilities")
        let older = try JSONDecoder().decode(FocusCheck.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(older.probabilities)
        XCTAssertNil(older.estimate(for: .onTask))
        XCTAssertNil(older.estimate(for: .uncertain))
        XCTAssertEqual(older.estimate(for: .offTask), 0.15)
        let skipped = FocusCheck(elapsed: 60, activity: .unavailable, probability: 0.99, confidence: 0.99)
        XCTAssertNil(skipped.estimate(for: .offTask))
    }
    func testEncryptedMessagesRejectReplayWrongKeyAndWrongDirection() throws {
        let key = Data(repeating: 7, count: 32), challenge = Data(repeating: 4, count: 32)
        var phone = SecureChannel(secret: key, challenge: challenge, server: false)
        var mac = SecureChannel(secret: key, challenge: challenge, server: true)
        let line = try phone.seal(Packet(command: "focusStart", text: "private task"))
        XCTAssertFalse(String(data: line, encoding: .utf8)!.contains("private task"))
        XCTAssertEqual(try mac.open(line).command, "focusStart")
        XCTAssertThrowsError(try mac.open(line))
        var wrong = SecureChannel(secret: Data(repeating: 8, count: 32), challenge: challenge, server: true)
        XCTAssertThrowsError(try wrong.open(line))
        XCTAssertThrowsError(try phone.open(line))
        let proof = SecureChannel.proof(secret: key, challenge: challenge)
        XCTAssertTrue(SecureChannel.verifies(proof, secret: key, challenge: challenge))
        XCTAssertFalse(SecureChannel.verifies(proof, secret: key, challenge: Data(repeating: 5, count: 32)))
    }
    func testPairingCodeRoundTripAndInvalidInput() {
        let record = PairingRecord(service: "Riley's Mac", secret: Data(repeating: 1, count: 32))
        XCTAssertEqual(PairingRecord.parse(record.qrText), record)
        XCTAssertNil(PairingRecord.parse("https://example.com"))
        XCTAssertNil(PairingRecord.parse(PairingRecord(service: "Mac", secret: Data([1])).qrText))
        let renamed = PairingRecord(service: "Riley's Mac (3)", secret: record.key!)
        XCTAssertEqual(record.identifier, renamed.identifier) // Bonjour renaming never changes pairing identity.
    }
}
