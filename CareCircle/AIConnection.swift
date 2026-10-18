import SwiftUI
import Security
import Speech
import AVFoundation

enum ConnectionError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum ConnectionToken {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.harryhutchins.carecircle.connection",
         kSecAttrAccount as String: "backend-token"]
    }

    static func read() -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ConnectionError.message("Couldn’t save your connection securely. Please try again.")
        }
    }
}

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    let role: String
    let content: String
    enum CodingKeys: String, CodingKey { case role, content }
}

struct CareCircleAPI {
    let address: String
    let token: String

    static func validatedURL(_ address: String) throws -> URL {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw ConnectionError.message("Enter your Care Circle server address, such as https://care.example.com.")
        }
        if url.scheme == "https" { return url }
        #if targetEnvironment(simulator)
        if url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host) { return url }
        #endif
        throw ConnectionError.message("Use an HTTPS server address to protect your conversations.")
    }

    func request(_ path: String, messages: [ChatMessage]? = nil) async throws -> Data {
        let base = try Self.validatedURL(address)
        guard !token.isEmpty else { throw ConnectionError.message("Add your connection token in the menu first.") }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = 110
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let messages {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["messages": messages])
        }
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ConnectionError.message("The server returned an unexpected response.")
        }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let error: String }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw ConnectionError.message(failure?.error ?? "Couldn’t reach Care Circle. Please try again.")
        }
        return data
    }

    func reply(to messages: [ChatMessage]) async throws -> String {
        struct Reply: Decodable { let reply: String }
        let data = try await request("chat", messages: messages)
        let reply = try JSONDecoder().decode(Reply.self, from: data).reply
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectionError.message("The response was empty. Please try again.")
        }
        return reply
    }
}

struct ConnectionSettingsView: View {
    @AppStorage("careCircleServerAddress") private var address = ""
    @State private var draftAddress = ""
    @State private var token = ""
    @State private var status: String?
    @State private var checking = false
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                TextField("https://your-care-circle-server", text: $draftAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityLabel("Care Circle server address")
                SecureField("Connection token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Care Circle connection")
            } footer: {
                Text("Use the connection token for your Care Circle server. Your Oracle account credentials stay on the server.")
            }
            Section {
                Button(checking ? "Checking…" : "Save and check connection") {
                    checkTask = Task { await checkConnection() }
                }
                .disabled(checking)
                if let status { Text(status).font(.callout).accessibilityAddTraits(.updatesFrequently) }
            }
            Section {
                Text("Messages you send are processed by Oracle Cloud. Conversations are held only while this chat is open in the app; the development server does not save or log them.")
                    .font(.footnote)
            }
        }
        .navigationTitle("AI connection")
        .onAppear {
            draftAddress = address
            token = ConnectionToken.read()
            #if targetEnvironment(simulator)
            if draftAddress.isEmpty { draftAddress = "http://localhost:8787" }
            #endif
        }
        .onDisappear { checkTask?.cancel() }
    }

    @MainActor private func checkConnection() async {
        checking = true
        status = nil
        defer { checking = false }
        do {
            let trimmed = draftAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try CareCircleAPI.validatedURL(trimmed)
            guard token.count >= 32 else { throw ConnectionError.message("Enter the full server connection token.") }
            try ConnectionToken.save(token)
            address = trimmed
            _ = try await CareCircleAPI(address: trimmed, token: token).request("health")
            try Task.checkCancellation()
            status = "Connected to your Care Circle server. You can start a conversation."
        } catch is CancellationError {
        } catch {
            status = error.localizedDescription
        }
    }
}

@MainActor
final class VoiceInput: ObservableObject {
    @Published var transcript = ""
    @Published var isListening = false
    @Published var error: String?
    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var tapInstalled = false
    private var starting = false
    private var generation = UUID()

    func start() async {
        guard !isListening && !starting else { return }
        starting = true
        error = nil
        let currentGeneration = UUID()
        generation = currentGeneration
        defer { starting = false }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled, generation == currentGeneration else { return }
        guard speech && microphone else {
            error = "Allow microphone and speech access in iPhone Settings to use voice. You can also type below."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            error = "On-device speech recognition isn’t available. Please type your message instead."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            self.request = request
            transcript = ""
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 && format.channelCount > 0 else {
                throw ConnectionError.message("The microphone isn’t ready. Please try again.")
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, failure in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if result?.isFinal == true || failure != nil {
                        if failure != nil && self.isListening {
                            self.error = "Voice input stopped. You can review or edit your message before sending."
                        }
                        self.stop()
                    }
                }
            }
        } catch {
            stop()
            self.error = error.localizedDescription
        }
    }

    func stop() {
        generation = UUID()
        isListening = false
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct ConversationView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("careCircleServerAddress") private var address = ""
    @StateObject private var voice = VoiceInput()
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var error: String?
    @State private var isSending = false
    @State private var work: Task<Void, Never>?
    @State private var readAloud = true
    @State private var speaker = AVSpeechSynthesizer()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if messages.isEmpty {
                                Text("What’s on your mind?").font(.title2.weight(.medium))
                                Text("Speak or type a message, then tap Send. Your messages are processed by Oracle Cloud.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(messages) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.role == "user" ? "You" : "Care Circle")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(message.content).textSelection(.enabled)
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(message.role == "user" ? 0.35 : 0.65), in: RoundedRectangle(cornerRadius: 18))
                                .id(message.id)
                            }
                            if isSending { ProgressView("Thinking…").id("thinking") }
                            if let error = error ?? voice.error {
                                Text(error).font(.callout).foregroundStyle(.red)
                            }
                        }
                        .padding(24)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }

                if address.isEmpty || ConnectionToken.read().isEmpty {
                    NavigationLink("Set up AI connection") { ConnectionSettingsView() }
                        .padding()
                }

                VStack(spacing: 12) {
                    TextField("Your message", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(14)
                        .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                        .disabled(isSending)
                    HStack {
                        Button {
                            speaker.stopSpeaking(at: .immediate)
                            if voice.isListening { voice.stop() }
                            else { work = Task { await voice.start() } }
                        } label: {
                            Label(voice.isListening ? "Stop listening" : "Speak", systemImage: voice.isListening ? "stop.fill" : "mic.fill")
                        }
                        .disabled(isSending)
                        Spacer()
                        Button("Send", systemImage: "arrow.up") {
                            voice.stop()
                            work = Task { await send() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || address.isEmpty)
                    }
                    Toggle("Read replies aloud", isOn: $readAloud).font(.footnote)
                }
                .padding(20)
            }
            .background(Color(red: 0.89, green: 0.85, blue: 0.74).ignoresSafeArea())
            .tint(Color(red: 0.57, green: 0.21, blue: 0.35))
            .navigationTitle("Care Circle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: voice.transcript) { _, transcript in draft = transcript }
            .onChange(of: readAloud) { _, enabled in if !enabled { speaker.stopSpeaking(at: .immediate) } }
            .onDisappear {
                work?.cancel()
                voice.stop()
                speaker.stopSpeaking(at: .immediate)
            }
        }
    }

    @MainActor private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        guard text.count <= 4000 else { error = "Please keep each message under 4,000 characters."; return }
        isSending = true
        error = nil
        speaker.stopSpeaking(at: .immediate)
        defer { isSending = false }
        let userMessage = ChatMessage(role: "user", content: text)
        // Keep the most recent nine complete exchanges, then the new user message.
        let history = Array(messages.suffix(18)) + [userMessage]
        do {
            let reply = try await CareCircleAPI(address: address, token: ConnectionToken.read()).reply(to: history)
            try Task.checkCancellation()
            messages.append(userMessage)
            messages.append(ChatMessage(role: "assistant", content: reply))
            draft = ""
            if readAloud {
                let audio = AVAudioSession.sharedInstance()
                try? audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                let utterance = AVSpeechUtterance(string: reply)
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                speaker.speak(utterance)
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
