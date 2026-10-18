import SwiftUI

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
                    case .speaking: voice.begin()
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
        .sheet(isPresented: $showMenu) { MenuSheet() }
        .onDisappear { voice.end() }
    }

    private func diameter(_ size: CGSize) -> CGFloat {
        min(voice.isActive ? 220 : 180, size.width * (voice.isActive ? 0.57 : 0.48), size.height * 0.34)
    }
}

private struct MenuSheet: View {
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

#Preview {
    ContentView()
}
