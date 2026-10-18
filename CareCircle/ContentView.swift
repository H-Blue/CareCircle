import SwiftUI
import AVFoundation

private enum CareStyle {
    static let cream = Color(red: 0.89, green: 0.85, blue: 0.74)
    static let ink = Color(red: 0.13, green: 0.12, blue: 0.10)
    static let burgundy = Color(red: 0.57, green: 0.21, blue: 0.35)
    static let rose = Color(red: 0.73, green: 0.45, blue: 0.55)
}

struct ContentView: View {
    @StateObject private var voice = CareCircleVoiceSession()
    @StateObject private var calendar = CareCalendarStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showMenu = false
    @State private var selectedHomeVisit: SavedVisit?
    @State private var showCalendarConnection = false
    @Namespace private var menuMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var greetingSize = 32

    private var openingText: String {
        switch voice.phase {
        case .idle, .connecting: return "Hi, what can I\nhelp with?"
        case .listening: return voice.isMuted ? "Microphone paused." : voice.transcript.isEmpty ? "I’m listening." : voice.transcript
        case .thinking: return voice.transcript
        case .speaking: return voice.reply
        case .failed: return voice.reply.isEmpty ? "Let’s try again." : voice.reply
        }
    }

    private var status: String {
        switch voice.phase {
        case .idle: return ""
        case .connecting: return "Connecting…"
        case .listening: return voice.isMuted ? "Microphone paused" : "Listening"
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
                ZStack {
                    CareStyle.cream.ignoresSafeArea()
                    homeScreen
                        .opacity(showMenu ? 0 : 1)
                        .allowsHitTesting(!showMenu)
                        .accessibilityHidden(showMenu)
                    if showMenu {
                        AppointmentMenu(store: voice.visits, calendar: calendar, motion: menuMotion, close: { setMenu(false) })
                            .transition(.opacity)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !showMenu, !voice.isActive, let notice = voice.notice {
                Text(notice).font(.footnote).multilineTextAlignment(.center).padding(24)
                    .foregroundStyle(CareStyle.ink.opacity(0.7)).allowsHitTesting(false)
            }
        }
        .sheet(item: $selectedHomeVisit) { visit in
            NavigationStack {
                VisitDetailView(store: voice.visits, id: visit.id)
                    .safeAreaInset(edge: .bottom) {
                        Button("Back to home") { selectedHomeVisit = nil }
                            .foregroundStyle(CareStyle.burgundy)
                            .frame(maxWidth: .infinity).padding(20)
                            .background(CareStyle.cream)
                    }
            }
            .presentationBackground(CareStyle.cream)
            .presentationDragIndicator(.visible)
        }
        .onDisappear { voice.end() }
        .sheet(isPresented: $showCalendarConnection) {
            NavigationStack {
                CalendarIntegrationView(store: calendar)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showCalendarConnection = false }
                    } }
            }
            .presentationBackground(CareStyle.cream)
        }
        .onOpenURL { url in
            guard url.scheme == "carecircle", url.host == "appointment", voice.activeVisit == nil else { return }
            voice.end()
            showCalendarConnection = true
        }
        .task { await calendar.refreshIfEnabled() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await calendar.refreshIfEnabled() } }
        }
        #if DEBUG
        .task {
            // UI checks can exercise local recording without spending a conversation session.
            if ProcessInfo.processInfo.arguments.contains("--test-record-visit") { voice.startVisit() }
            if ProcessInfo.processInfo.arguments.contains("--test-summary-home") {
                UserDefaults.standard.removeObject(forKey: "careCircleDismissedHomeBrief")
                let sample = SavedVisit(id: UUID(uuidString: "5B17C687-29EF-4B37-B6C6-113417B75583")!, date: .now,
                    lines: [VisitLine(text: "Clinician: Your X-ray shows no fracture. Please schedule a follow-up appointment in two weeks.", elapsed: 0)],
                    duration: 10, complete: true)
                try? voice.visits.save(sample)
            }
        }
        #endif
    }

    private func setMenu(_ open: Bool) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.65, dampingFraction: 0.88)) {
            showMenu = open
        }
    }

    private var homeScreen: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if !voice.isActive && !showMenu {
                    Button { setMenu(true) } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(0..<3) { index in
                                Rectangle().fill(CareStyle.ink.opacity(0.5))
                                    .matchedGeometryEffect(id: index, in: menuMotion)
                                    .frame(width: 62, height: 1)
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
                        if voice.phase == .idle {
                            HomeVisitBrief(store: voice.visits, greetingSize: greetingSize) { selectedHomeVisit = $0 }
                        } else {
                            Text(openingText)
                                .font(.system(size: voice.phase == .speaking ? min(greetingSize, 25) : greetingSize, weight: .regular, design: .rounded))
                                .foregroundStyle(CareStyle.ink)
                                .multilineTextAlignment(.leading)
                                .lineSpacing(5)
                                .frame(maxWidth: .infinity, minHeight: geometry.size.height * 0.25 - (voice.isActive ? 38 : 0), alignment: .leading)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    .scrollIndicators(.hidden)
                    if voice.isActive {
                        Text(status).font(.subheadline).foregroundStyle(CareStyle.ink.opacity(0.65))
                    }
                }
                .frame(width: min(geometry.size.width * (voice.isActive ? 0.62 : 0.78), 440), height: geometry.size.height * (voice.isActive ? 0.25 : 0.38))
                .position(x: geometry.size.width / 2, y: geometry.size.height * (voice.isActive ? 0.24 : 0.32))

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
                .accessibilityLabel(voice.phase == .listening ? (voice.isMuted ? "Resume microphone" : "Pause microphone") : "Speak to Care Circle")
                .accessibilityHint("Starts ElevenLabs voice. Speak naturally, or tap while listening to pause your microphone.")
                .position(x: geometry.size.width / 2, y: geometry.size.height * (voice.isActive ? 0.59 : 0.68))
                .animation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.75), value: voice.bass)
                .animation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.75), value: voice.treble)

                if voice.isActive {
                    VStack(spacing: 16) {
                        if let error = voice.error {
                            Text(error).font(.callout).multilineTextAlignment(.center).foregroundStyle(CareStyle.ink)
                        } else {
                            Text(voice.phase == .listening ? "Speak naturally. You can interrupt me." : "")
                                .font(.footnote).foregroundStyle(CareStyle.ink.opacity(0.65))
                        }
                        Button("End conversation") { voice.end() }
                            .font(.body.weight(.medium))
                            .foregroundStyle(CareStyle.burgundy)
                            .padding(.vertical, 12)
                        Text("Conversations use ElevenLabs. Visit transcripts use Oracle.")
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

private struct HomeVisitBrief: View {
    @ObservedObject var store: VisitStore
    let greetingSize: CGFloat
    let openVisit: (SavedVisit) -> Void
    @AppStorage("careCircleDismissedHomeBrief") private var dismissedID = ""
    private var latest: SavedVisit? { store.visits.first { $0.archived != true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let visit = latest, dismissedID != visit.id.uuidString {
                if let summary = visit.summary, !summary.isEmpty {
                    Text("Your visit, in plain language.")
                        .font(.subheadline).foregroundStyle(CareStyle.ink.opacity(0.65))
                    Text(summary)
                        .font(.system(size: 23, weight: .regular, design: .rounded))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("Home visit summary")
                    if !visit.complete || visit.transcriptionIssue != nil {
                        Text("This recap uses an incomplete transcript.")
                            .font(.footnote).foregroundStyle(CareStyle.burgundy)
                    }
                    HStack(spacing: 24) {
                        Button("View appointment") { openVisit(visit) }
                        Button("Got it") { dismissedID = visit.id.uuidString }
                    }
                    .font(.subheadline).foregroundStyle(CareStyle.burgundy)
                } else if visit.transcriptText.isEmpty {
                    Text("Want to listen back to your appointment?")
                        .font(.system(size: greetingSize, weight: .regular, design: .rounded))
                    Text("There isn’t enough transcribed speech for a summary.")
                        .font(.callout).foregroundStyle(CareStyle.ink.opacity(0.65))
                    Button("View recording") { openVisit(visit) }.foregroundStyle(CareStyle.burgundy)
                } else if let error = visit.summaryError {
                    Text("Let’s make your appointment easier to understand.")
                        .font(.system(size: 27, weight: .regular, design: .rounded))
                    Text(error).font(.callout).foregroundStyle(CareStyle.ink.opacity(0.65))
                    Button("Try summary again") { store.summarize(visit.id) }.foregroundStyle(CareStyle.burgundy)
                } else {
                    Text("I’m putting your appointment into plain language.")
                        .font(.system(size: 27, weight: .regular, design: .rounded))
                    ProgressView("Preparing your short recap…").font(.callout)
                    Button("View appointment") { openVisit(visit) }.foregroundStyle(CareStyle.burgundy)
                }
            } else {
                Text("Hi, what can I\nhelp with?")
                    .font(.system(size: greetingSize, weight: .regular, design: .rounded))
                    .lineSpacing(5)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .foregroundStyle(CareStyle.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: latest?.id) {
            // Resume an unfinished recap if the app was closed while it was being generated.
            if let visit = latest, dismissedID != visit.id.uuidString,
               visit.summary == nil, visit.summaryError == nil, !visit.transcriptText.isEmpty {
                store.summarize(visit.id)
            }
        }
    }
}

private struct AppointmentMenu: View {
    @ObservedObject var store: VisitStore
    @ObservedObject var calendar: CareCalendarStore
    let motion: Namespace.ID
    let close: () -> Void
    private var appointments: [SavedVisit] { store.visits.filter { $0.archived != true } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = store.storageError {
                        Text(error).font(.footnote).padding(.vertical, 12)
                    }
                    ForEach(Array(appointments.enumerated()), id: \.element.id) { index, visit in
                        SwipeAppointmentRow(store: store, visit: visit, latest: index == 0)
                        rule(index)
                    }
                    if appointments.isEmpty {
                        Text("Latest appointment").font(.title2).padding(.vertical, 24)
                        rule(0)
                        Text("Your recorded appointments will appear here.")
                            .foregroundStyle(CareStyle.ink.opacity(0.65)).padding(.vertical, 24)
                    }
                    // The three menu strokes become the first three appointment rules.
                    ForEach(max(appointments.count, 1)..<max(appointments.count, 3), id: \.self) { index in
                        Color.clear.frame(height: 68).accessibilityHidden(true)
                        rule(index)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
            }
            .scrollIndicators(.hidden)
            .background(CareStyle.cream.ignoresSafeArea())
            .foregroundStyle(CareStyle.ink)
            .navigationTitle("Appointments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CareStyle.cream, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    NavigationLink { ArchivedAppointments(store: store) } label: {
                        Image(systemName: "archivebox")
                    }.accessibilityLabel("Archived appointments")
                    NavigationLink { ConnectionSettingsView() } label: {
                        Image(systemName: "gearshape")
                    }.accessibilityLabel("AI connection")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink { CalendarIntegrationView(store: calendar) } label: {
                        Image(systemName: "calendar")
                    }.accessibilityLabel("Apple Calendar & transport")
                    Button("Done", action: close)
                }
            }
            .tint(CareStyle.ink)
        }
        .background(CareStyle.cream.ignoresSafeArea())
    }

    @ViewBuilder private func rule(_ index: Int) -> some View {
        if index < 3 {
            Rectangle().fill(CareStyle.ink.opacity(0.5))
                .matchedGeometryEffect(id: index, in: motion)
                .frame(height: 1)
        } else {
            Rectangle().fill(CareStyle.ink.opacity(0.5)).frame(height: 1)
        }
    }
}

private struct SwipeAppointmentRow: View {
    @ObservedObject var store: VisitStore
    let visit: SavedVisit
    let latest: Bool
    @State private var offset: CGFloat = 0
    @State private var openTranscript = false
    @State private var lastSwipe = Date.distantPast

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                withAnimation { store.setArchived(visit.id, true) }
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "archivebox")
                    Text("Archive").font(.caption)
                }
                .frame(width: 84, height: 80)
                .foregroundStyle(CareStyle.burgundy)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(offset == 0)
            Button {
                // A horizontal swipe must reveal Archive without also opening the row.
                guard Date().timeIntervalSince(lastSwipe) > 0.3 else { return }
                if offset < 0 { withAnimation { offset = 0 } }
                else { openTranscript = true }
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    if latest { Text("Latest appointment").font(.title2) }
                    Text(visit.date, format: .dateTime.month(.wide).day().year())
                        .font(latest ? .body : .title2)
                        .foregroundStyle(CareStyle.ink.opacity(latest ? 0.65 : 1))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 24)
                .padding(.horizontal, 8)
                .background(CareStyle.cream)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("appointment-" + visit.id.uuidString)
            .offset(x: offset)
            .simultaneousGesture(DragGesture(minimumDistance: 20).onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                lastSwipe = .now
                offset = min(0, max(-84, value.translation.width))
            }.onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                lastSwipe = .now
                withAnimation(.easeOut(duration: 0.2)) { offset = value.translation.width < -35 ? -84 : 0 }
            })
            .accessibilityAction(named: "Archive") { store.setArchived(visit.id, true) }
        }
        .clipped()
        .navigationDestination(isPresented: $openTranscript) {
            VisitDetailView(store: store, id: visit.id)
        }
    }
}

private struct ArchivedAppointments: View {
    @ObservedObject var store: VisitStore
    private var archived: [SavedVisit] { store.visits.filter { $0.archived == true } }
    var body: some View {
        List {
            if archived.isEmpty { Text("No archived appointments.").listRowBackground(CareStyle.cream) }
            ForEach(archived) { visit in
                NavigationLink {
                    VisitDetailView(store: store, id: visit.id)
                } label: {
                    Text(visit.date, format: .dateTime.month().day().year().hour().minute())
                }
                .listRowBackground(CareStyle.cream)
                .swipeActions {
                    Button("Restore") { store.setArchived(visit.id, false) }.tint(CareStyle.burgundy)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CareStyle.cream.ignoresSafeArea())
        .navigationTitle("Archived appointments")
        .toolbarBackground(CareStyle.cream, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct VisitRecordingView: View {
    @ObservedObject var voice: CareCircleVoiceSession
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
    @Environment(\.dismiss) private var dismiss
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CareStyle.cream.ignoresSafeArea())
        .navigationTitle("Visit transcript")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CareStyle.cream, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(CareStyle.ink)
        .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in
            if value.translation.width < -100 && abs(value.translation.width) > abs(value.translation.height) * 1.5,
               visit?.archived != true {
                store.setArchived(id, true)
                if store.visits.first(where: { $0.id == id })?.archived == true { dismiss() }
            }
        })
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("AI summary") { showSummary = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let archiving = visit?.archived != true
                    store.setArchived(id, archiving)
                    if archiving && store.visits.first(where: { $0.id == id })?.archived == true { dismiss() }
                } label: {
                    Image(systemName: visit?.archived == true ? "arrow.uturn.backward" : "archivebox")
                }
                .accessibilityLabel(visit?.archived == true ? "Restore" : "Archive")
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CareStyle.cream.ignoresSafeArea())
                .toolbarBackground(CareStyle.cream, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .tint(CareStyle.ink)
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
