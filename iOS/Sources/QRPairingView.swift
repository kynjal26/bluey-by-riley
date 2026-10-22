import SwiftUI
import AVFoundation

struct QRPairingView: View {
    @ObservedObject var link: MacLink
    @Environment(\.dismiss) private var dismiss
    @State private var error = ""
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("Pair your Mac").font(.fredoka(24)); Spacer(); Button("Done") { dismiss() } }
            Text("Open Bluey's Mac menu > Pair iPhone (QR), then scan the code. Your phone and Mac must be on the same network.")
                .font(.plexSans(14))
            QRScanner { text in
                guard let record = PairingRecord.parse(text) else { error = "That isn't a Bluey pairing code."; return }
                if link.pair(record) { dismiss() } else { error = "Couldn't save pairing securely. Try again." }
            } failure: { error = $0 }
            if !error.isEmpty { Text(error).font(.plexSans(13)).foregroundStyle(.orange) }
        }.padding(20).background(Color.black).preferredColorScheme(.dark)
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    var scanned: (String) -> Void
    var failure: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController(); vc.scanned = scanned; vc.failure = failure; return vc
    }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var scanned: ((String) -> Void)?
    var failure: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "bluey.qr")
    private var preview: AVCaptureVideoPreviewLayer?
    private var stopped = false
    override func viewDidLoad() {
        super.viewDidLoad()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                guard granted else { self.failure?("Enable Camera for Bluey in iPhone Settings to scan the pairing code."); return }
                self.configure()
            }
        }
    }
    private func configure() {
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            failure?("Camera isn't available."); return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { failure?("QR scanning isn't available."); return }
        session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds; view.layer.addSublayer(preview); self.preview = preview
        queue.async { [session] in session.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { stopped = true; queue.async { [session] in session.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !stopped, let text = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        if PairingRecord.parse(text) != nil { stop() }
        scanned?(text)
    }
}
