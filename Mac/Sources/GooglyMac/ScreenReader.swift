import AppKit
import ScreenCaptureKit
import Vision

/// One thing on screen the character can point at or click: a control, a line of text or a single word.
struct Target {
    let id: String
    let text: String
    /// In overlay coordinates: points, top-left origin, y down.
    let rect: CGRect
}

struct ScreenSnapshot {
    let jpeg: Data
    let lines: [(line: Target, words: [Target])]
    let size: CGSize
    /// The frontmost app and its clickable controls (empty without Accessibility permission).
    var app: String? = nil
    var controls: [ControlsReader.Control] = []

    func target(_ id: String) -> Target? {
        let id = id.trimmingCharacters(in: .whitespaces).uppercased()
        if let control = controls.first(where: { $0.id == id }) {
            return Target(id: control.id, text: control.label.isEmpty ? control.kind : control.label, rect: control.rect)
        }
        for entry in lines {
            if entry.line.id == id { return entry.line }
            if let word = entry.words.first(where: { $0.id == id }) { return word }
        }
        return nil
    }

    /// What's under (or right next to) a point: the smallest word, line or control there.
    func target(near point: CGPoint) -> Target? {
        var candidates: [Target] = controls.map { Target(id: $0.id, text: $0.label.isEmpty ? $0.kind : $0.label, rect: $0.rect) }
        for entry in lines { candidates.append(entry.line); candidates += entry.words }
        if let hit = candidates.filter({ $0.rect.insetBy(dx: -6, dy: -6).contains(point) })
            .min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
            return hit
        }
        func distance(_ r: CGRect) -> CGFloat {
            hypot(max(r.minX - point.x, 0, point.x - r.maxX), max(r.minY - point.y, 0, point.y - r.maxY))
        }
        return candidates.filter { distance($0.rect) < 60 }.min { distance($0.rect) < distance($1.rect) }
    }

    /// The list Claude picks from. Coordinates are on a 0–1000 grid so it can relate them to the image.
    var targetList: String {
        func grid(_ r: CGRect) -> String {
            let x = Int(r.midX / size.width * 1000), y = Int(r.midY / size.height * 1000)
            return "@\(x),\(y)"
        }
        var out: [String] = []
        if let app { out.append("Frontmost app: \(app)") }
        if !controls.isEmpty {
            out.append("Controls (click these by id):")
            out += controls.map { c in
                "\(c.id) \(c.kind) \(grid(c.rect))" + (c.label.isEmpty ? "" : " \"\(c.label)\"")
            }
        }
        out.append("Text on screen (L = line, W = word, @x,y on a 0-1000 grid):")
        if lines.isEmpty { out.append("(no text found)") }
        out += lines.map { entry in
            let words = entry.words.count > 1 ? " | " + entry.words.map { "\($0.id)=\($0.text)" }.joined(separator: " ") : ""
            return "\(entry.line.id) \(grid(entry.line.rect)) \"\(entry.line.text)\"\(words)"
        }
        return out.joined(separator: "\n")
    }
}

enum ScreenReaderError: LocalizedError {
    case noDisplay
    var errorDescription: String? { "I couldn't find the main display to look at." }
}

/// Captures the main display (without Googly's own cursor and captions) and reads every word with its exact box.
enum ScreenReader {
    static func snapshot() async throws -> ScreenSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw ScreenReaderError.noDisplay
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier || $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let size = CGSize(width: display.width, height: display.height)
        // Read the front app's controls at the same time as the text.
        let controlsTask = Task.detached(priority: .userInitiated) { ControlsReader.read(screen: size) }
        let lines = try recognize(image, in: size)
        let controls = await controlsTask.value
        return ScreenSnapshot(jpeg: jpeg(image, maxEdge: 1100), lines: lines, size: size, app: controls.app, controls: controls.controls)
    }

    static func recognize(_ image: CGImage, in size: CGSize) throws -> [(line: Target, words: [Target])] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])

        func toScreen(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                   width: box.width * size.width, height: box.height * size.height)
        }

        var result: [(line: Target, words: [Target])] = []
        var wordCount = 0
        let observations = (request.results ?? []).sorted {
            // Reading order: top to bottom, then left to right.
            abs($0.boundingBox.maxY - $1.boundingBox.maxY) > 0.01 ? $0.boundingBox.maxY > $1.boundingBox.maxY : $0.boundingBox.minX < $1.boundingBox.minX
        }
        for (i, observation) in observations.prefix(400).enumerated() {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            let line = Target(id: "L\(i + 1)", text: text, rect: toScreen(observation.boundingBox))
            var words: [Target] = []
            if wordCount < 600 {
                text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, range, _, _ in
                    guard let word, let box = try? candidate.boundingBox(for: range)?.boundingBox else { return }
                    wordCount += 1
                    words.append(Target(id: "W\(wordCount)", text: word, rect: toScreen(box)))
                }
            }
            result.append((line, words))
        }
        return result
    }

    private static func jpeg(_ image: CGImage, maxEdge: CGFloat) -> Data {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(1, maxEdge / max(w, h))
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) ?? Data()
    }
}
