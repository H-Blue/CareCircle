import SwiftUI
import AVFoundation

private enum CareStyle {
    static let cream = Color(red: 0.89, green: 0.85, blue: 0.74)
    static let ink = Color(red: 0.13, green: 0.12, blue: 0.10)
    static let burgundy = Color(red: 0.57, green: 0.21, blue: 0.35)
    static let rose = Color(red: 0.73, green: 0.45, blue: 0.55)
}

struct ContentView: View {
    @StateObject private var voice = OracleVoiceSession()
    @State private var showMenu = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var greetingSize = 32

    private var openingText: String {
        switch voice.phase {
        case .idle, .connecting: return "Hi, what can I\nhelp with?"
        case .listening: return voice.transcript.isEmpty ? "I’m listening." : voice.transcript
        case .thinking: return voice.transcript
        case .speaking: return voice.reply
        case .failed: return voice.reply.isEmpty ? "Let’s try again." : voice.reply
        }
    }

    private var status: String {
        switch voice.phase {
        case .idle: return ""
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .thinking: return "Thinking…"
        case .speaking: return "Care Circle is speaking"
        case .failed: return "Voice paused"
        }
    }

    var body: some View {
        Group {
            if voice.activeVisit != nil {
                VisitRecordingView(voice: voice)
            } else {
                homeScreen
            }
        }
        .sheet(isPresented: $showMenu) { MenuSheet(store: voice.visits, startVisit: {
            showMenu = false
            voice.startVisit()
        }) }
        .overlay(alignment: .bottom) {
            if !voice.isActive, let notice = voice.notice {
                Text(notice).font(.footnote).multilineTextAlignment(.center).padding(24)
                    .foregroundStyle(CareStyle.ink.opacity(0.7)).allowsHitTesting(false)
            }
        }
        .onDisappear { voice.end() }
    }

    private var homeScreen: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if !voice.isActive {
                    Button { showMenu = true } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(0..<3) { _ in
                                Rectangle().fill(CareStyle.ink.opacity(0.8)).frame(width: 62, height: 1)
                            }
                        }
                        .frame(width: 76, height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open menu")
                    .padding(.leading, 24)
                    .padding(.top, 14)
                    .transition(.opacity)
                }

                VStack(alignment: .leading, spacing: 18) {
                    ScrollView {
                        Text(openingText)
                            .font(.system(size: voice.phase == .speaking ? min(greetingSize, 25) : greetingSize, weight: .regular, design: .rounded))
                            .foregroundStyle(CareStyle.ink)
                            .multilineTextAlignment(.leading)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height * 0.25 - (voice.isActive ? 38 : 0), alignment: .leading)
                            .accessibilityAddTraits(.isHeader)
                    }
                    .scrollIndicators(.hidden)
                    if voice.isActive {
                        Text(status).font(.subheadline).foregroundStyle(CareStyle.ink.opacity(0.65))
                    }
                }
                .frame(width: min(geometry.size.width * 0.62, 400), height: geometry.size.height * 0.25)
                .position(x: geometry.size.width / 2, y: geometry.size.height * (voice.isActive ? 0.24 : 0.31))

                Button {
                    switch voice.phase {
                    case .idle, .failed: voice.begin()
                    case .listening: voice.finishTurn()
                    case .speaking: voice.interruptReply()
                    case .connecting, .thinking: break
                    }
                } label: {
                    ZStack {
                        Circle().fill(CareStyle.rose)
                            .scaleEffect(reduceMotion ? 1 : 1 + voice.treble * 0.10)
                        Circle().fill(CareStyle.burgundy)
                            .scaleEffect(reduceMotion ? 0.82 : 0.82 + voice.bass * 0.11)
                    }
                    .frame(width: diameter(geometry.size), height: diameter(geometry.size))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voice.phase == .listening ? "Finish speaking" : "Speak to Care Circle")
                .accessibilityHint("Starts Oracle voice. Tap again while listening to finish your message.")
                .position(x: geometry.size.width / 2, y: geometry.size.height * (voice.isActive ? 0.59 : 0.68))
                .animation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.75), value: voice.bass)
                .animation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.75), value: voice.treble)

                if voice.isActive {
                    VStack(spacing: 16) {
                        if let error = voice.error {
                            Text(error).font(.callout).multilineTextAlignment(.center).foregroundStyle(CareStyle.ink)
                        } else {
                            Text(voice.phase == .listening ? "Pause when you’re done, or tap the circle." : "")
                                .font(.footnote).foregroundStyle(CareStyle.ink.opacity(0.65))
                        }
                        Button("End conversation") { voice.end() }
                            .font(.body.weight(.medium))
                            .foregroundStyle(CareStyle.burgundy)
                            .padding(.vertical, 12)
                        Text("Voice is processed by Oracle while listening.")
                            .font(.caption).foregroundStyle(CareStyle.ink.opacity(0.65))
                    }
                    .padding(.horizontal, 28)
                    .frame(width: geometry.size.width)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.86)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: voice.isActive)
        }
        .background(CareStyle.cream.ignoresSafeArea())
    }

    private func diameter(_ size: CGSize) -> CGFloat {
        min(voice.isActive ? 220 : 180, size.width * (voice.isActive ? 0.57 : 0.48), size.height * 0.34)
    }
}

private struct MenuSheet: View {
    @ObservedObject var store: VisitStore
    let startVisit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Image(systemName: "heart.circle")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(CareStyle.burgundy)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("A little support.\nA circle of care.")
                            .font(.largeTitle.weight(.medium))
                        Text("Care Circle is a space to ask questions, talk through your day, and find support for your health and wellbeing.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    Button { dismiss() } label: {
                        Label("Back to your day", systemImage: "house")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        VisitLibraryView(store: store)
                    } label: {
                        Label("Saved visits & AI summaries", systemImage: "text.document")
                    }
                    Button(action: startVisit) {
                        Label("Record a doctor visit", systemImage: "mic")
                    }
                    Text("Before recording, make sure everyone present agrees. Recordings and transcripts stay on this device; Oracle processes live speech and generates summaries.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("YOUR CARE CIRCLE")
                        .font(.caption.weight(.semibold))
                        .tracking(2)
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        ConnectionSettingsView()
                    } label: {
                        Label("AI connection", systemImage: "network")
                    }
                    .tint(CareStyle.burgundy)
                }
                .padding(28)
            }
            .foregroundStyle(CareStyle.ink)
            .background(CareStyle.cream.ignoresSafeArea())
            .navigationTitle("Care Circle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(CareStyle.burgundy)
                }
            }
        }
    }
}

private struct VisitRecordingView: View {
    @ObservedObject var voice: OracleVoiceSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(voice.finishingVisit ? "Saving…" : voice.isRecordingVisit ? "Recording…" : "Connecting…")
                    .font(.title.weight(.regular))
                Spacer()
                if let visit = voice.activeVisit {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.duration(context.date.timeIntervalSince(visit.date)))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let visit = voice.activeVisit {
                            if visit.lines.isEmpty && visit.partial.isEmpty {
                                Text("The live transcript will appear here.").foregroundStyle(.secondary)
                            }
                            ForEach(visit.lines) { line in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(Self.duration(line.elapsed)).font(.caption).foregroundStyle(.secondary)
                                    Text(line.text).font(.title3).textSelection(.enabled)
                                }
                            }
                            if !visit.partial.isEmpty { Text(visit.partial).font(.title3).foregroundStyle(.secondary) }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                }
                .overlay(Rectangle().stroke(CareStyle.ink.opacity(0.5), lineWidth: 1))
                .onChange(of: voice.activeVisit?.transcriptText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if let error = voice.error { Text(error).font(.footnote).foregroundStyle(CareStyle.burgundy) }
            if let issue = voice.activeVisit?.transcriptionIssue { Text(issue).font(.caption).foregroundStyle(CareStyle.burgundy) }
            else if voice.isRecordingVisit && !voice.audioIsBeingSent { Text("Connecting live transcription… Audio is recording.").font(.caption) }
            Button { voice.finishVisit() } label: {
                ZStack {
                    Circle().fill(CareStyle.rose).scaleEffect(reduceMotion ? 1 : 1 + voice.treble * 0.08)
                    Circle().fill(CareStyle.burgundy).scaleEffect(reduceMotion ? 0.82 : 0.82 + voice.bass * 0.10)
                    RoundedRectangle(cornerRadius: 3).fill(CareStyle.cream).frame(width: 22, height: 22)
                }
                .frame(width: 108, height: 108)
            }
            .buttonStyle(.plain).disabled(voice.finishingVisit)
            .accessibilityLabel("Finish visit recording")
            .frame(maxWidth: .infinity)
            Text("Tap to finish and save")
                .font(.footnote).frame(maxWidth: .infinity)
            Text("Make sure everyone agrees to being recorded. Keep Care Circle open while recording. Speakers aren’t identified automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).foregroundStyle(CareStyle.ink)
        .background(CareStyle.cream.ignoresSafeArea())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: voice.bass)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let seconds = max(0, Int(seconds))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct VisitLibraryView: View {
    @ObservedObject var store: VisitStore
    @State private var deleting: SavedVisit?
    var body: some View {
        List {
            if let error = store.storageError { Text(error).foregroundStyle(.red) }
            if store.visits.isEmpty { Text("Your recorded visits will appear here.").foregroundStyle(.secondary) }
            ForEach(store.visits) { visit in
                NavigationLink {
                    VisitDetailView(store: store, id: visit.id)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(visit.date, format: .dateTime.month().day().year().hour().minute())
                        Text(visit.complete ? "Transcript & AI summary" : "Interrupted visit • captured audio and text")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
                .swipeActions { Button("Delete", role: .destructive) { deleting = visit } }
            }
            Text("Saved on this device and excluded from cloud backups. Deleting the app removes these visits.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("Saved visits")
        .alert("Delete this visit?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete recording and transcript", role: .destructive) { if let deleting { store.delete(deleting) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This removes the saved audio, transcript and summary from this device.") }
    }
}

private struct VisitDetailView: View {
    @ObservedObject var store: VisitStore
    let id: UUID
    @State private var player: AVAudioPlayer?
    @State private var playbackError: String?
    @State private var playbackTask: Task<Void, Never>?
    @State private var showSummary = false
    private var visit: SavedVisit? { store.visits.first { $0.id == id } }

    var body: some View {
        ScrollView {
            if let visit {
                VStack(alignment: .leading, spacing: 24) {
                    Text(visit.date, format: .dateTime.month().day().year().hour().minute()).font(.headline)
                    Button { playbackTask?.cancel(); playbackTask = Task { await togglePlayback(visit) }
                    } label: { Label("Play / stop recording", systemImage: "play.circle") }
                    if let playbackError { Text(playbackError).font(.callout) }
                    if !visit.complete { Text("Recording was interrupted. This transcript may be incomplete.").font(.callout) }
                    if let issue = visit.transcriptionIssue { Text(issue).font(.callout).foregroundStyle(CareStyle.burgundy) }
                    Text(visit.transcriptText.isEmpty ? "No speech was transcribed. The captured recording is available above." : visit.transcriptText)
                        .font(.title3).lineSpacing(6).textSelection(.enabled)
                }.padding(24)
            }
        }
        .background(CareStyle.cream.ignoresSafeArea()).navigationTitle("Visit transcript")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("AI summary") { showSummary = true }
            }
        }
        .sheet(isPresented: $showSummary) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("AI summary").font(.largeTitle)
                        Text("Generated from your transcript. Check details against the recording, especially names, medications and dosages.").font(.footnote).foregroundStyle(.secondary)
                        if visit?.complete == false || visit?.transcriptionIssue != nil {
                            Text("This summary uses an incomplete transcript. Refer to the recording for missing discussion.").font(.callout).foregroundStyle(CareStyle.burgundy)
                        }
                        if let summary = visit?.summary { Text(summary).textSelection(.enabled) }
                        else if store.summarizing.contains(id) { ProgressView("Summarizing your visit…") }
                        else {
                            Text(visit?.summaryError ?? "A summary is available after speech has been transcribed.")
                            Button("Generate summary") { store.summarize(id) }.disabled(visit?.transcriptText.isEmpty != false)
                        }
                    }.padding(24)
                }
                .background(CareStyle.cream.ignoresSafeArea())
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSummary = false } } }
            }
        }
        .onDisappear {
            playbackTask?.cancel(); playbackTask = nil
            player?.stop(); player = nil
            AudioWork.deactivate()
        }
    }

    @MainActor private func togglePlayback(_ visit: SavedVisit) async {
        if player?.isPlaying == true { player?.stop(); player = nil; return }
        do {
            try await AudioWork.run {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
            }
            guard !Task.isCancelled else { return }
            let audio = try AVAudioPlayer(contentsOf: store.audioURL(visit))
            player = audio
            guard audio.play() else { throw ConnectionError.message("Couldn’t play this recording.") }
        } catch { playbackError = "This recording couldn’t play. Your transcript is available below." }
    }

}

#Preview {
    ContentView()
}
