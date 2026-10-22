import AppKit
import GooglyShared

/// Explicit opt-in developer probe. Uses synthetic images, never the user's desktop.
enum FocusDiagnostics {
    @MainActor static func run(realScreen: Bool = false) async -> Int32 {
        if realScreen {
            guard CGPreflightScreenCaptureAccess() else { print("LIVE desktop capture: Screen Recording permission missing"); return 1 }
            do {
                let screen = try await ScreenReader.snapshot()
                let decision = try await FocusAPI.classify(screen, session: FocusSession(task: "Build the Bluey focus friend Mac and iPhone apps"), idle: 0)
                print("LIVE desktop capture + Decisions: \(decision.activity.rawValue), P(off)=\(decision.probability), confidence=\(decision.confidence). No screenshot saved.")
                return 0
            } catch { print("LIVE desktop check failed: \(error.localizedDescription)"); return 1 }
        }
        for (name, title, task) in [
            ("supporting_tutorial", "CODEX TUTORIAL\nHow to build an app with Codex\nResearch for my next video", "Make a video teaching Codex"),
            ("unrelated_entertainment", "CAT COMPILATION\nFunny cats on trampolines\nUp next: more cat videos", "Prepare the monthly business expense report"),
            ("twitter_unrelated", "X / HOME / FOR YOU\nFunny football moments\nCelebrity drama and memes\nTrending: weekend plans\nScroll for more entertainment", "Work on the Bluey app inside the Codex app"),
            ("twitter_research", "X / SEARCH: SwiftUI Bonjour\nFix NWConnection pairing in SwiftUI\nTechnical guide to Bonjour discovery\nCheck service names and TXT records", "Fix Bonjour pairing in the Bluey SwiftUI app")
        ] {
            let image = NSImage(size: CGSize(width: 960, height: 600))
            image.lockFocus()
            NSColor(white: 0.1, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 960, height: 600).fill()
            (title as NSString).draw(in: NSRect(x: 50, y: 100, width: 860, height: 400),
                withAttributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.white])
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation, let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:]) else { return 1 }
            let size = CGSize(width: 960, height: 600)
            do {
                let lines: [(line: Target, words: [Target])]
                if name.hasPrefix("twitter"), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    lines = try ScreenReader.recognize(cg, in: size)
                } else { lines = [] }
                let screen = ScreenSnapshot(jpeg: jpeg, lines: lines, size: size,
                                            app: name.hasPrefix("twitter") ? "Safari" : nil)
                let result = try await FocusAPI.classify(screen, session: FocusSession(task: task), idle: 120)
                print("LIVE synthetic fixture \(name): \(result.activity.rawValue), P(off)=\(result.probability), confidence=\(result.confidence)")
                if name == "twitter_unrelated", result.activity != .offTask || result.probability < 0.5 { return 1 }
                if name == "twitter_research", result.activity != .onTask { return 1 }
                if name == "unrelated_entertainment" {
                    let nudge = try await FocusAPI.nudge(screen, task: task)
                    print("LIVE Responses nudge: \(nudge.message); target=\(nudge.target == nil ? "none" : "validated")")
                }
            } catch { print("LIVE API unavailable: \(error.localizedDescription)"); return 1 }
        }
        return 0
    }
}
