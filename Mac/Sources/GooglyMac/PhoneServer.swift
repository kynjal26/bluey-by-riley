import Foundation
import Network
import GooglyShared

/// Advertises the Mac on the local network and streams face updates to any phone that connects.
final class PhoneServer {
    private var listener: NWListener?
    private var phones: [ObjectIdentifier: (link: LineConnection, name: String?)] = [:]
    private var pending: [ObjectIdentifier: LineConnection] = [:]
    private var lastSent: FaceState?
    private var lastSentAt = Date.distantPast
    private var restartWork: DispatchWorkItem?

    /// Called with the names of connected phones whenever that list changes.
    var onPhonesChanged: (([String]) -> Void)?

    /// Called when a phone asks for something. The second argument replies to that phone.
    var onRequest: ((Packet, @escaping (Packet) -> Void) -> Void)?

    var phoneNames: [String] { phones.values.map { $0.name ?? "iPhone" } }

    func start() {
        do {
            let listener = try NWListener(using: .googly)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: GooglyService.type, txtRecord: NWTXTRecord(["bluey-id": MacPairing.record.identifier]))
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.scheduleRestart() }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("Googly: could not start listener: \(error)")
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        listener?.cancel()
        listener = nil
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.start() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func accept(_ connection: NWConnection) {
        let link = LineConnection(connection, secret: MacPairing.record.key!, server: true)
        let id = ObjectIdentifier(link)
        pending[id] = link  // keep it alive until it is ready
        link.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: break // Only authenticated peers become phones.
            case .failed, .cancelled:
                self.pending[id] = nil
                self.phones[id] = nil
                self.onPhonesChanged?(self.phoneNames)
            default:
                break
            }
        }
        link.onAuthenticated = { [weak self, weak link] in
            guard let self, let link else { return }
            self.pending[id] = nil
            self.phones[id] = (link, nil)
            link.send(Packet(hello: Host.current().localizedName ?? "Mac"))
            if let face = self.lastSent { link.send(Packet(face: face)) }
            self.onPhonesChanged?(self.phoneNames)
        }
        link.onPacket = { [weak self, weak link] packet in
            guard let self, self.phones[id] != nil else { return }
            if let name = packet.hello {
                self.phones[id]?.name = name
                self.onPhonesChanged?(self.phoneNames)
            }
            if packet.command != nil {
                self.onRequest?(packet) { [weak link] response in link?.send(response) }
            }
        }
        link.start()
    }

    /// Sends a command to every phone (e.g. "wake", "sleep").
    func broadcast(_ packet: Packet) {
        for phone in phones.values { phone.link.send(packet) }
    }

    /// Sends the face to every phone, skipping updates too small to see.
    func send(_ face: FaceState) {
        // Resend at least once a second even when nothing changed, so the phone knows the Mac is still driving.
        let now = Date()
        if let last = lastSent, now.timeIntervalSince(lastSentAt) < 1,
           last.mood == face.mood,
           abs(last.gazeX - face.gazeX) < 0.004,
           abs(last.gazeY - face.gazeY) < 0.004,
           abs(last.talk - face.talk) < 0.02 {
            return
        }
        lastSent = face
        lastSentAt = now
        for phone in phones.values { phone.link.send(Packet(face: face)) }
    }
}
