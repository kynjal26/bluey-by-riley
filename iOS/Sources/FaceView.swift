import SwiftUI

/// A tiny damped spring, so every part of the face moves with a little life.
private struct Spring {
    var value: Double
    var velocity = 0.0
    let stiffness: Double
    let damping: Double  // 1 = no overshoot, lower = bouncier

    init(_ value: Double, stiffness: Double = 200, damping: Double = 0.7) {
        self.value = value
        self.stiffness = stiffness
        self.damping = damping
    }

    mutating func step(to target: Double, dt: Double) {
        let c = 2 * sqrt(stiffness) * damping
        velocity += (stiffness * (target - value) - c * velocity) * dt
        value += velocity * dt
    }
}

/// Smooths what the Mac asks for into lifelike motion: darting eyes, brows, blinks, leaning, hops.
final class FaceAnimator {
    struct Frame {
        var gaze: CGPoint
        var mood: Mood
        var talk: Double
        var closed: Double      // 0 open … 1 shut (blink)
        var breathe: Double
        var time: Double
        var pupil: Double       // pupil size multiplier
        var browLift: Double    // + raises the brows (in design px)
        var browTilt: Double    // + worried/curious, - focused (radians)
        var lean: Double        // head tilt toward where he's looking (radians)
        var hop: Double         // little idle hop (design px, up is +)
        var blush: Double       // 0…1
        var squint: Double      // 0…1 happy squint from below
    }

    private var target = FaceState()
    private var lastPacket = -100.0
    private var gazeX = Spring(0, stiffness: 260, damping: 0.82)
    private var gazeY = Spring(0, stiffness: 260, damping: 0.82)
    private var pupil = Spring(1, stiffness: 160, damping: 0.5)
    private var browLift = Spring(0, stiffness: 180, damping: 0.55)
    private var browTilt = Spring(0, stiffness: 150, damping: 0.6)
    private var lean = Spring(0, stiffness: 60, damping: 0.8)
    private var hop = Spring(0, stiffness: 260, damping: 0.35)
    private var blush = Spring(0.25, stiffness: 40, damping: 1)
    private var squint = Spring(0, stiffness: 150, damping: 0.7)
    private var talk = 0.0
    private var mood: Mood = .listening
    private var moodChanged = 0.0
    private var blinkStart = -1.0
    private var doubleBlink = false
    private var nextBlink = 2.0
    private var lastTime: Double?
    private var nextSaccade = 0.0
    private var wanderTarget = CGPoint(x: 0, y: -0.3)
    private var jitter = CGPoint.zero
    private var nextJitter = 0.0
    private var nextHop = 6.0

    /// Set while a finger is on the screen, in -1…1 gaze units.
    var touchGaze: CGPoint?
    /// Mood set on the phone itself (waking up, talking).
    var localMood: Mood?
    /// Loudness of the voice playing on this phone, 0…1.
    var localTalk: () -> Double = { 0 }
    /// True while he's awake and talking with you. In follow mode his eyes stay locked on your mouse.
    var awake = false

    func receive(_ face: FaceState, at time: Double) {
        target = face
        lastPacket = time
    }

    func step(_ now: Double) -> Frame {
        let dt = min(now - (lastTime ?? now), 1.0 / 20)
        lastTime = now

        let live = now - lastPacket < 2.5
        let wantedMood = localMood ?? (live ? target.mood : .listening)
        if wantedMood != mood {
            mood = wantedMood
            moodChanged = now
            blinkStart = now          // blink through every mood change
            if mood != .sleepy && mood != .resting {
                hop.velocity += 260   // and a little bounce of surprise
                pupil.velocity += 3
            }
        }

        // Where to look, plus tiny darting movements so the eyes never sit dead still.
        var want: CGPoint
        if let touchGaze {
            want = touchGaze
        } else if live {
            want = CGPoint(x: target.gazeX, y: target.gazeY)
        } else {
            if now > nextSaccade {
                wanderTarget = CGPoint(x: .random(in: -0.9...0.9), y: .random(in: -0.9...0.4))
                nextSaccade = now + .random(in: 0.6...2.2)
            }
            want = wanderTarget
        }
        if mood == .thinking { want = CGPoint(x: 0.6 + 0.08 * sin(now * 1.3), y: -0.85) }
        if now > nextJitter {
            // While he's listening his eyes stay on your mouse; the livelier darting is for replying.
            let amount = !awake ? 0.015 : (mood == .talking ? 0.07 : mood == .thinking ? 0.05 : 0.02)
            jitter = CGPoint(x: .random(in: -amount...amount), y: .random(in: -amount...amount))
            nextJitter = now + .random(in: 0.5...1.4)
        }
        gazeX.step(to: want.x + jitter.x, dt: dt)
        gazeY.step(to: want.y + jitter.y, dt: dt)

        var wantTalk = live ? target.talk : (localMood == .talking ? 0.5 + 0.5 * sin(now * 19) * sin(now * 7.3) : 0)
        wantTalk = max(wantTalk, localTalk())
        talk += (wantTalk - talk) * min(1, dt * 25)

        // Expression targets per mood.
        var wantPupil = 1.0, wantLift = 0.0, wantTilt = 0.0, wantBlush = 0.25, wantSquint = 0.0
        switch mood {
        case .listening:
            wantPupil = 1.12; wantLift = 10
        case .talking:
            wantPupil = 1.05; wantLift = 6 + talk * 18; wantTilt = 0.05 * sin(now * 2.3)
        case .pointing:
            wantPupil = 0.95; wantLift = -4; wantTilt = -0.14
        case .thinking:
            wantPupil = 0.9; wantLift = 4; wantTilt = 0.22
        case .happy:
            wantPupil = 1.2; wantLift = 16; wantBlush = 0.85; wantSquint = 1
        case .resting:
            wantPupil = 0.9; wantLift = -8; wantBlush = 0.15
        case .sleepy:
            wantPupil = 0.88; wantLift = -10; wantTilt = 0.12; wantBlush = 0.15
        }
        pupil.step(to: wantPupil, dt: dt)
        browLift.step(to: wantLift, dt: dt)
        browTilt.step(to: wantTilt, dt: dt)
        blush.step(to: wantBlush, dt: dt)
        squint.step(to: wantSquint, dt: dt)
        lean.step(to: -gazeX.value * 0.045, dt: dt)

        // An occasional happy little hop when nothing much is going on.
        if now > nextHop {
            if talk < 0.05, mood != .sleepy, mood != .resting { hop.velocity += .random(in: 180...320) }
            nextHop = now + .random(in: 7...14)
        }
        hop.step(to: 0, dt: dt)

        // Blinks, sometimes doubled.
        // Blinks, sometimes doubled. When he's drowsy they're slow and heavy.
        let drowsy = mood == .sleepy
        if now > nextBlink {
            blinkStart = now
            doubleBlink = !drowsy && Double.random(in: 0...1) < 0.25
            nextBlink = now + (drowsy ? .random(in: 1.6...3.0) : .random(in: 2.0...5.0))
        }
        let p = (now - blinkStart) / (drowsy ? 0.7 : 0.15)
        var closed = (0...1).contains(p) ? sin(.pi * p) : 0
        if doubleBlink, (1.3...2.3).contains(p) { closed = sin(.pi * (p - 1.3)) }

        let breathe = sin(now * (mood == .resting ? 1.1 : 1.8))
        return Frame(gaze: CGPoint(x: gazeX.value, y: gazeY.value), mood: mood, talk: talk, closed: closed,
                     breathe: breathe, time: now, pupil: pupil.value, browLift: browLift.value,
                     browTilt: browTilt.value, lean: lean.value, hop: hop.value, blush: blush.value,
                     squint: max(0, min(1, squint.value)))
    }
}

/// The landscape face on pure black: he fills the screen and peeks up from the bottom edge.
struct FaceView: View {
    let animator: FaceAnimator

    // The design is drawn on an 844 × 390 landscape phone.
    static let design = CGSize(width: 844, height: 390)

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let frame = animator.step(timeline.date.timeIntervalSinceReferenceDate)
                FaceView.draw(frame, in: &ctx, size: size)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    /// Fills a shape with his skin (gradient plus the same soft shine), for eyelids.
    private static func fillSkin(_ path: Path, in ctx: inout GraphicsContext, body: CGRect) {
        ctx.fill(path, with: BlobShape.fill(in: body))
        ctx.fill(path, with: .radialGradient(Gradient(colors: [.white.opacity(0.5), .white.opacity(0)]),
                                             center: CGPoint(x: body.minX + 246, y: body.minY + 126),
                                             startRadius: 0, endRadius: 243))
    }

    static func draw(_ f: FaceAnimator.Frame, in ctx: inout GraphicsContext, size: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

        let scale = max(size.width / design.width, size.height / design.height)
        ctx.translateBy(x: (size.width - design.width * scale) / 2, y: size.height - design.height * scale)
        ctx.scaleBy(x: scale, y: scale)

        // Whole-body motion: breathing, talking bounce, idle hops, and leaning toward what he looks at.
        let bounce = -f.talk * 16 + f.breathe * 3 - f.hop
        let body = CGRect(x: 12, y: 44 + bounce, width: 820, height: 700)
        let pivot = CGPoint(x: body.midX, y: body.maxY)
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: .radians(f.lean))
        let stretch = 1 + min(0.03, max(-0.03, f.hop / 900))
        ctx.scaleBy(x: 2 - stretch, y: stretch)
        ctx.translateBy(x: -pivot.x, y: -pivot.y)

        let blob = BlobShape.path(in: body)

        ctx.fill(blob, with: .color(Color(hex: Palette.berry3)))

        ctx.fill(blob, with: BlobShape.fill(in: body))
        var shine = ctx
        shine.clip(to: blob)
        shine.fill(blob, with: .radialGradient(Gradient(colors: [.white.opacity(0.5), .white.opacity(0)]),
                                               center: CGPoint(x: body.minX + 246, y: body.minY + 126),
                                               startRadius: 0, endRadius: 243))
        // A little glossy sparkle on his head.
        shine.fill(Path(ellipseIn: CGRect(x: body.minX + 190, y: body.minY + 40, width: 46, height: 22)),
                   with: .color(.white.opacity(0.35)))

        let navy = Color(hex: Palette.nose)
        let ink = Color(hex: Palette.ink)
        ctx.fill(Crown.path(in: CGRect(x: body.minX + 368, y: body.minY - 20 - f.browLift * 0.3, width: 84, height: 56)),
                 with: .color(navy))

        let eyeY = body.minY + 157
        let eyes = [CGPoint(x: body.minX + 280, y: eyeY), CGPoint(x: body.minX + 540, y: eyeY)]
        let squash = 1 - f.talk * 0.12

        // Blushy cheeks, rosier when he's happy.
        for (i, c) in eyes.enumerated() {
            let side: CGFloat = i == 0 ? -1 : 1
            let cheek = CGRect(x: c.x - 45 + side * 62, y: c.y + 96, width: 90, height: 42)
            var soft = ctx
            soft.addFilter(.blur(radius: 10))
            soft.fill(Path(ellipseIn: cheek), with: .color(Color(hex: 0xF3A6D8, opacity: 0.25 + 0.45 * f.blush)))
        }

        for (i, c) in eyes.enumerated() {
            let side: CGFloat = i == 0 ? -1 : 1

            // Little arched eyebrows do a lot of the acting.
            var brow = ctx
            let browY = c.y - 112 - min(18, max(-10, f.browLift)) * 0.7
            brow.translateBy(x: c.x + side * 6, y: browY)
            brow.rotate(by: .radians(f.browTilt * Double(side) * -1 + (f.mood == .thinking && i == 1 ? -0.25 : 0)))
            var arch = Path()
            arch.move(to: CGPoint(x: -38, y: 6))
            arch.addQuadCurve(to: CGPoint(x: 38, y: 6), control: CGPoint(x: 0, y: -12))
            brow.stroke(arch, with: .color(navy), style: StrokeStyle(lineWidth: 14, lineCap: .round))

            switch f.mood {
            case .resting:
                // Peacefully closed: a soft downward curve.
                var shut = Path()
                shut.move(to: CGPoint(x: c.x - 62, y: c.y + 6))
                shut.addQuadCurve(to: CGPoint(x: c.x + 62, y: c.y + 6), control: CGPoint(x: c.x, y: c.y + 52))
                ctx.stroke(shut, with: .color(ink), style: StrokeStyle(lineWidth: 18, lineCap: .round))

            case .happy where f.squint > 0.6:
                var arc = Path()
                arc.move(to: CGPoint(x: c.x - 60, y: c.y + 34))
                arc.addQuadCurve(to: CGPoint(x: c.x + 60, y: c.y + 34), control: CGPoint(x: c.x, y: c.y - 54))
                ctx.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: 24, lineCap: .round))

            default:
                let open = max(0.06, 1 - f.closed) * squash
                let white = CGRect(x: c.x - 95, y: c.y - 95 * open, width: 190, height: 190 * open)
                let whitePath = Path(ellipseIn: white)
                ctx.fill(whitePath, with: .color(.white))
                guard open > 0.2 else { continue }

                var g = f.gaze
                let len = hypot(g.x, g.y)
                if len > 1 { g = CGPoint(x: g.x / len, y: g.y / len) }
                // Eyes converge a little when looking down close, and reach further for a livelier look.
                let reach: CGFloat = 50
                let r = 46 * f.pupil
                var pupil = CGPoint(x: c.x + g.x * reach - side * 3, y: c.y + g.y * reach * open)
                if f.mood == .sleepy { pupil.y = max(pupil.y, c.y) + 28 }  // eyes sink under heavy lids
                var inside = ctx
                inside.clip(to: whitePath)
                inside.fill(Path(ellipseIn: CGRect(x: pupil.x - r, y: pupil.y - r, width: r * 2, height: r * 2)), with: .color(ink))
                // Two catchlights make them shine.
                inside.fill(Path(ellipseIn: CGRect(x: pupil.x - r * 0.58, y: pupil.y - r * 0.72, width: r * 0.56, height: r * 0.56)),
                            with: .color(.white))
                inside.fill(Path(ellipseIn: CGRect(x: pupil.x + r * 0.28, y: pupil.y + r * 0.22, width: r * 0.24, height: r * 0.24)),
                            with: .color(.white.opacity(0.85)))
                // Happy cheeks push up from below as he smiles.
                if f.squint > 0.02 {
                    let lid = CGRect(x: c.x - 110, y: c.y + 95 * open - 70 * f.squint, width: 220, height: 160)
                    fillSkin(Path(ellipseIn: lid), in: &inside, body: body)
                }
                // Heavy, droopy lids when he's getting sleepy.
                if f.mood == .sleepy {
                    let droop = 0.5 + 0.06 * sin(f.time * 1.3)
                    fillSkin(Path(CGRect(x: c.x - 100, y: white.minY - 10, width: 200, height: white.height * droop + 10)),
                             in: &inside, body: body)
                    inside.stroke(Path { p in
                        p.move(to: CGPoint(x: c.x - 92, y: white.minY + white.height * droop))
                        p.addLine(to: CGPoint(x: c.x + 92, y: white.minY + white.height * droop))
                    }, with: .color(navy.opacity(0.7)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                }
                // A soft upper lid when he's focused on pointing.
                if f.mood == .pointing {
                    fillSkin(Path(CGRect(x: c.x - 100, y: white.minY - 20, width: 200, height: 40)), in: &inside, body: body)
                }
            }
        }

        if f.mood == .resting {
            // Little z's floating up while he naps.
            for i in 0..<3 {
                let phase = (f.time * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let size = 26 + CGFloat(i) * 8
                let point = CGPoint(x: body.minX + 660 + CGFloat(phase) * 70 + CGFloat(sin(phase * 6)) * 8,
                                    y: body.minY + 90 - CGFloat(phase) * 110)
                ctx.draw(Text("z").font(.fredoka(size)).foregroundColor(.white.opacity(0.9 * sin(.pi * phase))), at: point)
            }
        }

        if f.mood == .thinking {
            for i in 0..<3 {
                let wobble = sin(f.time * 3 + Double(i)) * 4
                let dot = CGRect(x: body.minX + 690 + CGFloat(i) * 26, y: body.minY + 40 - CGFloat(i) * 12 + wobble, width: 16, height: 16)
                ctx.fill(Path(ellipseIn: dot), with: .color(.white.opacity(1 - Double(i) * 0.3)))
            }
        }

        // His little mouth-nose: opens as he talks, curls into a smile when he's happy.
        let noseW: CGFloat = 60 - f.talk * 8
        let noseH: CGFloat = 38 + f.talk * 34
        let nose = CGRect(x: body.minX + 410 - noseW / 2, y: body.minY + 272 - f.talk * 6, width: noseW, height: noseH)
        if f.mood == .happy && f.talk < 0.1 {
            var smile = Path()
            smile.move(to: CGPoint(x: nose.minX - 8, y: nose.minY + 8))
            smile.addQuadCurve(to: CGPoint(x: nose.maxX + 8, y: nose.minY + 8), control: CGPoint(x: nose.midX, y: nose.minY + 58))
            smile.closeSubpath()
            ctx.fill(smile, with: .color(navy))
        } else {
            ctx.fill(Path(ellipseIn: nose), with: .color(navy))
            if f.talk > 0.25 {
                let tongue = CGRect(x: nose.midX - noseW * 0.28, y: nose.maxY - noseH * 0.38, width: noseW * 0.56, height: noseH * 0.3)
                ctx.fill(Path(ellipseIn: tongue), with: .color(Color(hex: 0xE58BC4, opacity: 0.9)))
            }
        }
    }
}
