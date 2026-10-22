import XCTest
import CryptoKit
@testable import GooglyShared

final class FocusTests: XCTestCase {
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
        for bad in [#"{"answers":[{"type":"refusal","name":"activity"}]}"#, "{}", String(data: good, encoding: .utf8)!.replacingOccurrences(of: "0.8", with: "1.8")] {
            XCTAssertThrowsError(try FocusDecision.decode(Data(bad.utf8)))
        }
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
