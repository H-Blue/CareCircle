import SwiftUI

private enum CareStyle {
    static let cream = Color(red: 0.89, green: 0.85, blue: 0.74)
    static let ink = Color(red: 0.13, green: 0.12, blue: 0.10)
    static let burgundy = Color(red: 0.57, green: 0.21, blue: 0.35)
    static let rose = Color(red: 0.73, green: 0.45, blue: 0.55)
}

struct ContentView: View {
    @State private var activeSheet: HomeSheet?
    @ScaledMetric(relativeTo: .title) private var greetingSize = 32

    private enum HomeSheet: String, Identifiable {
        case menu, voice
        var id: String { rawValue }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Button {
                        activeSheet = .menu
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(0..<3) { _ in
                                Rectangle()
                                    .fill(CareStyle.ink.opacity(0.8))
                                    .frame(width: 62, height: 1)
                            }
                        }
                        .frame(width: 76, height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open menu")
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)

                Spacer(minLength: 24)

                Text("Hi, what can I\nhelp with?")
                    .font(.system(size: greetingSize, weight: .regular, design: .rounded))
                    .foregroundStyle(CareStyle.ink)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 40)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 32)

                Button {
                    activeSheet = .voice
                } label: {
                    Circle()
                        .fill(CareStyle.burgundy)
                        .overlay {
                            Circle()
                                .strokeBorder(CareStyle.rose, lineWidth: 14)
                        }
                        .frame(width: buttonDiameter(in: geometry.size), height: buttonDiameter(in: geometry.size))
                        .contentShape(Circle())
                }
                .buttonStyle(SpeakButtonStyle())
                .accessibilityLabel("Speak to Care Circle")
                .accessibilityHint("Opens a conversation with Care Circle")

                Spacer(minLength: 36)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(CareStyle.cream.ignoresSafeArea())
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .menu:
                MenuSheet()
            case .voice:
                ConversationView()
            }
        }
    }

    private func buttonDiameter(in size: CGSize) -> CGFloat {
        min(180, max(120, min(size.width * 0.48, size.height * 0.25)))
    }
}

private struct SpeakButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
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

                    Text("EARLY PREVIEW")
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
