import Foundation
import SwiftUI
import Security

enum PhonePairing {
    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "co.visionairy.googly.pairing", kSecAttrAccount as String: service]
    }
    static func load() -> PairingRecord? {
        let service = UserDefaults.standard.string(forKey: "preferredMac") ?? "mac"
        var q = query(service); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return try? JSONDecoder().decode(PairingRecord.self, from: data)
        }
        var legacy = query("mac"); legacy[kSecReturnData as String] = true; legacy[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(legacy as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let record = try? JSONDecoder().decode(PairingRecord.self, from: data), record.service == service else { return nil }
        _ = save(record)
        return record
    }
    static func save(_ record: PairingRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        SecItemDelete(query(record.service) as CFDictionary)
        var q = query(record.service); q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}

final class FocusClient: ObservableObject {
    @Published private(set) var current: FocusSession?
    @Published private(set) var history: [FocusSession] = []
    @Published private(set) var fresh = false
    @Published var message = ""
    var onFinished: (() -> Void)?
    private var revision = -1
    private var receivedAt = Date.distantPast
    private var timer: Timer?
    private weak var link: MacLink?
    private var file: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bluey-focus-history.json") }
    init() {
        history = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([FocusSession].self, from: $0) } ?? []
    }
    func attach(_ link: MacLink) {
        self.link = link
        writeStatus()
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.link?.connected == true { self.link?.send(Packet(command: "focusPing")) }
            if Date().timeIntervalSince(self.receivedAt) > 5 { self.fresh = false }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func connectionChanged(_ connected: Bool) {
        fresh = false; revision = -1
        if connected { link?.send(Packet(command: "focusSync")) }
        writeStatus()
    }
    func receive(_ text: String) {
        guard let state = try? JSONDecoder().decode(FocusSync.self, from: Data(text.utf8)), state.revision > revision else { return }
        let finished = current != nil && current?.id == state.current?.id && current?.status != .ended && state.current?.status == .ended
        revision = state.revision; receivedAt = Date(); fresh = true
        current = state.current; history = state.history
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: file, options: .atomic) }
        writeStatus()
        if finished { onFinished?() }
    }
    private func writeStatus() {
        let status: [String: Any] = ["build": "focus-friend-1", "connected": link?.connected == true,
            "fresh": fresh, "sessionStatus": current?.status.rawValue ?? "none", "revision": revision,
            "updatedAt": Date().timeIntervalSince1970]
        let target = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bluey-status.json")
        if let data = try? JSONSerialization.data(withJSONObject: status) { try? data.write(to: target, options: .atomic) }
    }
    func command(_ command: String, task: String? = nil, minutes: Double = 30) {
        guard let link, link.connected else { message = "Connect your paired Mac first."; return }
        let data = try? JSONSerialization.data(withJSONObject: ["task": task ?? "", "minutes": minutes])
        link.request(Packet(command: command, text: data.flatMap { String(data: $0, encoding: .utf8) })) { [weak self] reply in
            self?.message = reply?.text ?? "The Mac didn't answer. Monitoring will pause if disconnected."
        }
    }
}
