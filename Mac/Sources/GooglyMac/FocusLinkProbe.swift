import AppKit
import Network
import GooglyShared

/// Explicit developer integration probe against the running app, never a replacement for
/// a phone/voice test. Uses the real encrypted transport, clock, capture and Decisions path.
@MainActor
final class FocusLinkProbe {
    private var browser: NWBrowser?
    private var link: LineConnection?
    private var timer: Timer?
    private var complete: ((Int32) -> Void)?
    private let began = Date()
    private let task = "Bluey integration test: build the focus friend Mac and iPhone apps"
    private var phase = "discover"
    private var pausedAt = Date.distantFuture
    private var pausedElapsed = 0.0
    private var resumedElapsed = 0.0
    private var checked = false
    private let developerTest: Bool
    private var previousDeveloperMode = false
    private init(developerMode: Bool) { developerTest = developerMode }

    static func run(developerMode: Bool = false) async -> Int32 {
        let probe = FocusLinkProbe(developerMode: developerMode)
        return await withCheckedContinuation { continuation in
            probe.complete = { continuation.resume(returning: $0) }
            probe.start()
        }
    }
    private func start() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: GooglyService.type, domain: nil), using: .googly)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.found(results) }
        }
        browser.start(queue: .main); self.browser = browser
        let timer = Timer(timeInterval: 1, repeats: true) { [self] _ in
            Task { @MainActor in
                send("focusPing")
                if phase == "paused", Date().timeIntervalSince(pausedAt) >= 3 {
                    print("LIVE app clock: paused without advancing")
                    phase = "resuming"; send("focusResume")
                }
                if Date().timeIntervalSince(began) > 80 { finish(1, "timed out in \(phase)") }
            }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func found(_ results: Set<NWBrowser.Result>) {
            guard link == nil, let result = results.first(where: {
                if case let .bonjour(record) = $0.metadata { return record.getEntry(for: "bluey-id") == .string(MacPairing.record.identifier) }; return false
            }) else { return }
            let connection = LineConnection(NWConnection(to: result.endpoint, using: .googly), secret: MacPairing.record.key!, server: false)
            link = connection
            connection.onAuthenticated = { [self] in
                Task { @MainActor in
                print("LIVE app transport: authenticated")
                phase = "initial"
                connection.send(Packet(hello: "Bluey integration probe"))
                send("focusSync")
                }
            }
            connection.onPacket = { [self] packet in Task { @MainActor in receive(packet) } }
            connection.start()
    }
    private func send(_ command: String) {
        var text: String?
        if command == "focusStart" {
            text = (try? JSONSerialization.data(withJSONObject: ["task": task, "minutes": developerTest ? 2 : 1])).flatMap { String(data: $0, encoding: .utf8) }
        } else if command == "focusDeveloperMode" {
            text = (try? JSONSerialization.data(withJSONObject: ["developerMode": phase == "restoring" ? previousDeveloperMode : true])).flatMap { String(data: $0, encoding: .utf8) }
        }
        link?.send(Packet(command: command, text: text))
    }
    private func receive(_ packet: Packet) {
        guard packet.command == "focusState", let text = packet.text,
              let state = try? JSONDecoder().decode(FocusSync.self, from: Data(text.utf8)) else { return }
        if phase == "initial" {
            if let session = state.current, session.status != .ended { finish(2, "active user session; skipped"); return }
            previousDeveloperMode = state.developerMode ?? false
            if developerTest { phase = "configuring"; send("focusDeveloperMode"); return }
            phase = "starting"; send("focusStart"); return
        }
        if phase == "configuring", state.developerMode == true {
            print("LIVE Developer Mode: enabled and synchronized")
            phase = "starting"; send("focusStart"); return
        }
        if phase == "restoring", state.developerMode == previousDeveloperMode {
            finish(0, "4x clock and ten-second checks verified; original setting restored"); return
        }
        guard let session = state.current, session.task == task else { return }
        if phase == "starting", session.status == .running { phase = "running"; print("LIVE app focus: started") }
        if phase == "running", let check = session.checks.last, check.activity != .paused {
            checked = [.onTask, .offTask, .uncertain].contains(check.activity)
            print("LIVE scheduled check at \(Int(check.elapsed))s: \(check.activity.rawValue)")
            if developerTest {
                guard session.isDeveloperMode, check.sampleDuration == 40,
                      check.elapsed >= 39, check.elapsed < 60,
                      abs(session.elapsed - session.realActiveElapsed * 4) < 0.1 else {
                    finish(1, "unexpected Developer Mode timing"); return
                }
                print("LIVE 4x clock: observation at \(String(format: "%.1f", check.elapsed / 4)) real seconds")
            }
            phase = "pausing"; send("focusPause")
        } else if phase == "pausing", session.status == .paused {
            pausedElapsed = session.elapsed; pausedAt = Date(); phase = "paused"
        } else if phase == "paused" {
            if abs(session.elapsed - pausedElapsed) > 0.05 { finish(1, "pause advanced the clock") }
        } else if phase == "resuming", session.status == .running {
            print("LIVE app focus: resumed")
            resumedElapsed = session.elapsed; phase = "resumed"
        } else if phase == "resumed", session.elapsed - resumedElapsed >= 2 {
            phase = "ending"; send("focusEnd")
        } else if phase == "ending", session.status == .ended {
            guard state.history.contains(where: { $0.id == session.id }), checked else { finish(1, "ended, but no valid live check/history"); return }
            if developerTest { phase = "restoring"; send("focusDeveloperMode"); return }
            finish(0, "pause/resume/end synchronized; history contains the live check")
        }
    }
    private func finish(_ code: Int32, _ note: String) {
        guard let complete else { return }
        self.complete = nil
        print("LIVE app integration: \(note)")
        timer?.invalidate(); link?.cancel(); browser?.cancel()
        complete(code)
    }
}
