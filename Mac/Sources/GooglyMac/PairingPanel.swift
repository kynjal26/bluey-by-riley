import AppKit
import CoreImage.CIFilterBuiltins
import CryptoKit
import GooglyShared

enum MacPairing {
    static let record: PairingRecord = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Googly")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("pairing-secret")
        let key: Data
        if let saved = try? Data(contentsOf: file), saved.count == 32 { key = saved }
        else {
            key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            do { try key.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            catch { fatalError("Could not save the private pairing credential") }
        }
        return PairingRecord(service: Host.current().localizedName ?? "Mac", secret: key)
    }()
}

@MainActor
final class PairingPanel {
    private var panel: NSPanel?
    func show() {
        if let panel { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 440, height: 510), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Pair Bluey"; panel.isReleasedWhenClosed = false
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(MacPairing.record.qrText.utf8)
        let view = NSImageView(frame: CGRect(x: 80, y: 155, width: 280, height: 280))
        if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
           let cg = CIContext().createCGImage(output, from: output.extent) {
            view.image = NSImage(cgImage: cg, size: NSSize(width: 280, height: 280))
        }
        panel.contentView?.addSubview(view)
        let title = NSTextField(labelWithString: "Your little focus friend")
        title.font = .systemFont(ofSize: 23, weight: .semibold); title.alignment = .center
        title.frame = CGRect(x: 20, y: 452, width: 400, height: 32); panel.contentView?.addSubview(title)
        let copy = NSTextField(wrappingLabelWithString: "On your iPhone, open Bluey and tap Pair Mac to scan this code. Keep the code private: it pairs your phone to this Mac.\n\nDuring focus sessions, your main display is shared with OpenAI every 30 seconds. No screenshots are saved by Bluey. Pause or end to stop sharing.")
        copy.font = .systemFont(ofSize: 13); copy.frame = CGRect(x: 30, y: 20, width: 380, height: 124)
        panel.contentView?.addSubview(copy)
        self.panel = panel; panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
