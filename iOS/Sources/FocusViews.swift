import SwiftUI

struct FocusFaceHUD: View {
    @ObservedObject var focus: FocusClient
    @ObservedObject var link: MacLink
    @ObservedObject var live: LiveVoice
    var open: () -> Void
    var pair: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(focus.current.flatMap { $0.status == .ended ? nil : $0.task } ?? "What's the mission?")
                        .font(.fredoka(22)).lineLimit(2)
                    Text(status).font(.plexMono(10)).foregroundStyle(.white.opacity(0.65))
                    if !live.feedback.isEmpty {
                        Text(live.feedback).font(.plexSans(12)).lineLimit(2).foregroundStyle(.white.opacity(0.85))
                    }
                    if live.state == .asking {
                        Capsule().fill(Color.white).frame(width: 20 + live.inputLevel * 100, height: 3)
                    }
                }.frame(maxWidth: 360, alignment: .leading)
                Spacer()
            }
            Spacer()
            HStack(spacing: 14) {
                if !link.connected {
                    Button("Pair Mac", action: pair)
                } else if let session = focus.current, session.status != .ended {
                    Button(session.status == .running ? "Pause" : "Resume") {
                        focus.command(session.status == .running ? "focusPause" : "focusResume")
                    }.disabled(!focus.fresh)
                    Button("End") { focus.command("focusEnd") }.disabled(!focus.fresh)
                }
                Button("Focus", action: open)
                Spacer()
            }.font(.plexSans(13).weight(.semibold)).buttonStyle(.bordered).tint(.white)
        }.foregroundStyle(.white).padding(.leading, 24).padding(.top, 18).padding(.bottom, 12)
    }
    private var status: String {
        guard link.connected else { return "Pair your Mac to focus together" }
        guard let session = focus.current, session.status != .ended else { return "Hold Bluey and describe a task · 30 min default" }
        guard focus.fresh else { return "Connection lost · monitoring will pause" }
        return "\(FocusSession.clock(session.remaining)) · \(session.status == .paused ? "Paused" : "Focusing together")"
    }
}

struct FocusDashboard: View {
    @ObservedObject var focus: FocusClient
    @ObservedObject var link: MacLink
    @Environment(\.dismiss) private var dismiss
    @State private var task = ""
    @State private var minutes = 30.0
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let finished = focus.current, finished.status == .ended {
                        Text("Lovely bit of focus.").font(.fredoka(26))
                        FocusSummary(session: finished)
                            .padding(16).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let session = focus.current, session.status != .ended {
                        FocusSummary(session: session)
                        Text(focus.fresh ? session.detail : "Connection lost. Reconnect before resuming.")
                            .font(.plexSans(13)).foregroundStyle(.secondary)
                        HStack {
                            Button(session.status == .running ? "Pause" : "Resume") {
                                focus.command(session.status == .running ? "focusPause" : "focusResume")
                            }
                            Button("End focus") { focus.command("focusEnd") }
                        }.buttonStyle(.bordered).disabled(!link.connected || !focus.fresh)
                    } else {
                        Text("A little company. A little focus.").font(.fredoka(26))
                        Text("Hold Bluey and say what you're working on, or type it here.").font(.plexSans(14))
                        TextField("What are we working on?", text: $task).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("focusTask")
                        Stepper("\(Int(minutes)) minutes", value: $minutes, in: 1...240, step: 5)
                        Button("Start focus") { focus.command("focusStart", task: task, minutes: minutes) }
                            .buttonStyle(.borderedProminent).disabled(task.trimmingCharacters(in: .whitespaces).isEmpty || !link.connected)
                            .accessibilityIdentifier("startFocus")
                    }
                    if !focus.message.isEmpty { Text(focus.message).font(.plexSans(13)).foregroundStyle(.secondary) }
                    Text("While focusing, Bluey sends your main Mac display, task, elapsed time, idle duration and recent check results to OpenAI every 30 seconds. Brief detours are fine. Stillness isn't distraction.")
                        .font(.plexSans(13)).foregroundStyle(.secondary)
                    Text("Screen Recording is required on Mac; microphone is needed for voice. Screenshots aren't saved by Bluey. Pause, end, lock, sleep or disconnect stops capture. Resume is always manual. OpenAI processing follows your API account's data controls.")
                        .font(.plexSans(13)).foregroundStyle(.secondary)
                    Divider()
                    Text("Your focus sessions").font(.fredoka(23))
                    if focus.history.isEmpty { Text("Your first timeline will appear here when you finish.").foregroundStyle(.secondary) }
                    ForEach(focus.history) { session in
                        FocusSummary(session: session)
                            .padding(16).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(24)
            }.background(Color.black).navigationTitle("bluey · focus friend")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Back to Bluey") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(Color(hex: Palette.berry2))
    }
}

private struct FocusSummary: View {
    let session: FocusSession
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.task).font(.fredoka(22))
            Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(FocusSession.clock(session.elapsed)) active")
                .font(.plexMono(11)).foregroundStyle(.secondary)
            FocusTimeline(session: session).frame(height: 40)
            HStack(spacing: 16) {
                legend("On task", .green); legend("Detour", Color(hex: 0xEBAC73)); legend("Unknown / unchecked", .gray)
            }.font(.plexSans(11))
            Text("30-second observations, not an exact time audit. Pauses are excluded.")
                .font(.plexSans(11)).foregroundStyle(.secondary)
        }
    }
    private func legend(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 5) { Rectangle().fill(color).frame(width: 9, height: 9); Text(name) }
    }
}

struct FocusTimeline: View {
    let session: FocusSession
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.35)))
            let total = max(1, session.status == .ended ? session.elapsed : session.duration)
            for check in session.checks where [.onTask, .offTask].contains(check.activity) {
                let start = max(0, check.elapsed - 30)
                let rect = CGRect(x: start / total * size.width, y: 0,
                                  width: min(30, check.elapsed) / total * size.width, height: size.height)
                context.fill(Path(rect), with: .color(check.activity == .onTask ? .green : Color(hex: 0xEBAC73)))
            }
        }.overlay(Rectangle().stroke(.white.opacity(0.3), lineWidth: 1))
            .accessibilityLabel("Focus timeline: green on task, peach detours, grey unknown")
    }
}
