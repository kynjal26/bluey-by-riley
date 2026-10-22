import Foundation
import Network
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Finds the Mac app on the local network with Bonjour and keeps a connection open.
final class MacLink: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var macName: String?
    /// Every Mac running Bluey on this Wi-Fi, by its Bonjour name.
    @Published private(set) var macs: [String] = []
    /// The Mac the phone is linked to (or trying to link to).
    @Published private(set) var currentMac: String?
    /// The Mac picked in the speaker panel. Remembered, so the phone goes back to it on launch.
    @Published private(set) var preferredMac: String? = UserDefaults.standard.string(forKey: "preferredMac")
    /// Commands from the Mac, like "wake" and "sleep".
    var onCommand: ((String, String?) -> Void)?
    private var waiting: [String: (Packet?) -> Void] = [:]

    var onFocusState: ((String) -> Void)?

    var onFace: ((FaceState) -> Void)?

    private var browser: NWBrowser?
    private var link: LineConnection?
    private var retry: DispatchWorkItem?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: GooglyService.type, domain: nil), using: .googly)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.macs = results.compactMap(Self.serviceName).sorted()
            self.connectIfNeeded()
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.restart() }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        retry?.cancel()
        browser?.cancel()
        browser = nil
        link?.cancel()
        link = nil
        connected = false
        let pending = waiting; waiting = [:]; pending.values.forEach { $0(nil) }
    }

    private func restart() {
        stop()
        scheduleRetry()
    }

    private func scheduleRetry() {
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.browser == nil { self.start() } else { self.connectIfNeeded() }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Switches to another Mac and remembers the choice.
    func choose(_ name: String) {
        preferredMac = name
        UserDefaults.standard.set(name, forKey: "preferredMac")
        if currentMac != name { link?.cancel() }
        connectIfNeeded()
    }

    private static func serviceName(_ result: NWBrowser.Result) -> String? {
        if case let .service(name, _, _, _) = result.endpoint { return name }
        return nil
    }

    private func connectIfNeeded() {
        guard let pairing = PhonePairing.load(), let secret = pairing.key else { return }
        guard link == nil, let results = browser?.browseResults, !results.isEmpty else { return }
        guard let result = results.first(where: {
            guard case let .bonjour(record) = $0.metadata else { return false }
            return record.getEntry(for: "bluey-id") == .string(pairing.identifier)
        }) else { return }
        currentMac = Self.serviceName(result)
        let link = LineConnection(NWConnection(to: result.endpoint, using: .googly), secret: secret, server: false)
        link.onState = { [weak self, weak link] state in
            guard let self, let link, link === self.link else { return }
            switch state {
            case .ready: break // Authentication, not TCP readiness, marks a paired connection.
            case .failed, .cancelled:
                self.connected = false
                let waiting = self.waiting
                self.waiting = [:]
                waiting.values.forEach { $0(nil) }
                self.macName = nil
                self.link = nil
                self.scheduleRetry()
            case .waiting:
                link.cancel()
            default:
                break
            }
        }
        link.onAuthenticated = { [weak self, weak link] in
            guard let self, let link, link === self.link else { return }
            self.connected = true
            link.send(Packet(hello: Self.deviceName))
            link.send(Packet(command: "focusSync"))
        }
        link.onPacket = { [weak self] packet in
            if let name = packet.hello { self?.macName = name }
            if let face = packet.face { self?.onFace?(face) }
            guard let self, let command = packet.command else { return }
            if command == "focusState", let text = packet.text { self.onFocusState?(text); return }
            if let callID = packet.callID, let done = self.waiting.removeValue(forKey: callID) {
                done(packet)
            } else {
                self.onCommand?(command, packet.text)
            }
        }
        self.link = link
        link.start()
    }

    func pair(_ record: PairingRecord) -> Bool {
        guard PhonePairing.save(record) else { return false }
        stop()
        preferredMac = record.service
        UserDefaults.standard.set(record.service, forKey: "preferredMac")
        start()
        return true
    }

    func send(_ packet: Packet) {
        link?.send(packet)
    }

    /// Sends a request to the Mac and calls back with its reply (nil if the Mac went away).
    func request(_ packet: Packet, _ done: @escaping (Packet?) -> Void) {
        guard let link, connected else { done(nil); return }
        var packet = packet
        let id = UUID().uuidString
        packet.callID = id
        waiting[id] = done
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.waiting.removeValue(forKey: id)?(nil) }
        link.send(packet)
    }

    private static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Phone"
        #endif
    }
}
