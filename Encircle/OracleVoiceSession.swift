import Foundation
import UIKit
import AVFoundation
import Combine
import Dispatch
import ElevenLabs
import LiveKit

/// Audio route changes and engine setup may block; keep them off the UI thread.
enum AudioWork {
    static let queue = DispatchQueue(label: "com.encircle.audio-control")

    static func run(_ operation: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { try operation(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func deactivate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Owns the audio tap and converter. The render callback performs no networking or UI work.
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var hasTap = false
    private var recordingFile: AVAudioFile?

    func start(recordingURL: URL? = nil, onRecordingError: @escaping () -> Void = {}, deliver: @escaping (Data, Float, Float) -> Void) async throws {
        try await AudioWork.run { try self.startEngine(recordingURL: recordingURL, onRecordingError: onRecordingError, deliver: deliver) }
    }

    private func startEngine(recordingURL: URL?, onRecordingError: @escaping () -> Void, deliver: @escaping (Data, Float, Float) -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw ConnectionError.message("The microphone isn’t ready. Please try again.")
        }
        if let recordingURL {
            recordingFile = try AVAudioFile(forWriting: recordingURL, settings: source.settings)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: recordingURL.path)
        }
        var bands = VoiceBands()
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { buffer, _ in
            if let file = self.recordingFile {
                do { try file.write(from: buffer) } catch { onRecordingError(); return }
            }
            guard let samples = buffer.floatChannelData?[0] else { return }
            let levels = bands.levels(samples: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)), sampleRate: source.sampleRate)
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / source.sampleRate + 32)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, output.frameLength > 0, let bytes = output.int16ChannelData?[0] else { return }
            deliver(Data(bytes: bytes, count: Int(output.frameLength) * MemoryLayout<Int16>.size), levels.0, levels.1)
        }
        hasTap = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        AudioWork.queue.async {
            self.engine.stop()
            if self.hasTap { self.engine.inputNode.removeTap(onBus: 0); self.hasTap = false }
            self.recordingFile = nil
        }
    }
}

@MainActor
final class EncircleVoiceSession: NSObject, ObservableObject {
    enum Phase: String {
        case idle, connecting, listening, thinking, speaking, failed
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var bass: CGFloat = 0
    @Published private(set) var treble: CGFloat = 0
    @Published private(set) var transcript = ""
    @Published private(set) var reply = ""
    @Published private(set) var error: String?
    @Published private(set) var audioIsBeingSent = false
    @Published private(set) var activeVisit: SavedVisit?
    @Published private(set) var finishingVisit = false
    @Published private(set) var isRecordingVisit = false
    private var visitStream: AsyncStream<Data>?
    @Published private(set) var notice: String?
    let visits = VisitStore()
    private let microphone = MicrophoneCapture()
    private var socket: URLSessionWebSocketTask?
    private var socketSession: URLSession?
    private var task: Task<Void, Never>?
    private var finalizer: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var captureTimeout: Task<Void, Never>?
    private var audio: AsyncStream<Data>.Continuation?
    private var conversation: Conversation?
    // Keep the companion softer than full-level call audio, including after interruptions.
    private let agentPlaybackVolume: Double = 0.6
    private var subscriptions = Set<AnyCancellable>()
    private var inputMeter: ConversationMeter?
    private var voiceShutdown: Task<Void, Never>?
    private var handledTools = Set<String>()
    @Published private(set) var isMuted = false
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    var isActive: Bool { phase != .idle }

    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.end() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.end() }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private var api: EncircleAPI {
        EncircleAPI(address: UserDefaults.standard.string(forKey: "encircleServerAddress") ?? "", token: ConnectionToken.read())
    }

    func begin() {
        guard activeVisit == nil else { return }
        end()
        error = nil
        reply = ""
        transcript = ""
        notice = nil
        generation = UUID()
        let turn = generation
        task = Task { await connectElevenLabs(turn: turn) }
    }

    private func transcribeVisit(turn: UUID) async {
        guard generation == turn, !Task.isCancelled else { return }
        phase = .connecting
        transcript = ""
        do {
            let permission = await AVAudioApplication.requestRecordPermission()
            guard generation == turn, !Task.isCancelled else { return }
            guard permission else { throw ConnectionError.message("Allow microphone access in iPhone Settings to speak with Encircle.") }
            struct Session: Decodable { let token: String; let compartmentId: String; let endpoint: String }
            let data: Data
            if let context = visits.cloudContext {
                data = try await VisitCloudClient(token: context.token).session("speech", circle: context.circleID)
            } else { data = try await api.request("speech/session", post: true) }
            let session = try JSONDecoder().decode(Session.self, from: data)
            guard generation == turn, !Task.isCancelled else { return }
            guard var components = URLComponents(string: session.endpoint),
                  components.scheme == "wss", let host = components.host,
                  host.hasPrefix("realtime.aiservice."), host.hasSuffix(".oci.oraclecloud.com") else {
                throw ConnectionError.message("Oracle returned an unexpected voice endpoint.")
            }
            components.queryItems = [
                URLQueryItem(name: "encoding", value: "audio/raw;rate=16000"),
                URLQueryItem(name: "languageCode", value: "en-US"),
                URLQueryItem(name: "finalSilenceThresholdInMs", value: "1600"),
                URLQueryItem(name: "partialSilenceThresholdInMs", value: "300"),
                URLQueryItem(name: "isAckEnabled", value: "false"),
            ]
            guard let url = components.url else { throw ConnectionError.message("Couldn’t open Oracle voice.") }
            let urlSession = URLSession(configuration: .ephemeral)
            socketSession = urlSession
            let connection = urlSession.webSocketTask(with: url)
            socket = connection
            connection.resume()
            let auth = try JSONSerialization.data(withJSONObject: ["authenticationType": "TOKEN", "token": session.token, "compartmentId": session.compartmentId])
            try await connection.send(.string(String(decoding: auth, as: UTF8.self)))
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, self.generation == turn, self.phase == .connecting else { return }
                self.speechFailed("Oracle voice took too long to connect. Please try again.")
            }
            while generation == turn && !Task.isCancelled {
                let message = try await connection.receive()
                let body: Data
                switch message { case .string(let text): body = Data(text.utf8); case .data(let value): body = value; @unknown default: continue }
                guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any], let event = json["event"] as? String else { continue }
                if event == "CONNECT" {
                    timeout?.cancel()
                    try await capture(connection: connection, turn: turn)
                } else if event == "RESULT", let results = json["transcriptions"] as? [[String: Any]] {
                    for result in results {
                        if let text = result["transcription"] as? String, !text.isEmpty {
                            transcript = text
                            if var visit = activeVisit {
                                if result["isFinal"] as? Bool == true {
                                    visit.lines.append(VisitLine(text: text, elapsed: Date().timeIntervalSince(visit.date)))
                                    visit.partial = ""
                                } else { visit.partial = text }
                                activeVisit = visit
                                do { try visits.save(visit) }
                                catch { fail("Device storage is full. The visit was stopped to protect your recording."); return }
                                continue
                            }
                            if result["isFinal"] as? Bool == true {
                                return
                            }
                        }
                    }
                } else if event == "ERROR" {
                    throw ConnectionError.message("Oracle voice couldn’t continue. Please try again.")
                }
            }
        } catch {
            guard generation == turn, !Task.isCancelled, phase != .failed else { return }
            speechFailed(error.localizedDescription)
        }
    }

    private func capture(connection: URLSessionWebSocketTask, turn: UUID) async throws {
        guard phase == .connecting else { return }
        let stream: AsyncStream<Data>
        if let visitStream { stream = visitStream }
        else {
            stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(64)) { continuation in audio = continuation }
            try await startMicrophone(turn: turn)
        }
        guard generation == turn, !Task.isCancelled else { microphone.stop(); return }
        phase = .listening
        audioIsBeingSent = true
        sender = Task { [weak self] in
            do {
                for await data in stream {
                    try Task.checkCancellation()
                    try await connection.send(.data(data))
                }
            } catch {
                if !Task.isCancelled, self?.generation == turn { self?.speechFailed("The voice connection was interrupted. Please try again.") }
            }
        }
        if activeVisit == nil {
        captureTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, self.generation == turn else { return }
            self.fail("Listening paused after one minute. Tap the circle to continue.")
        }
        }
    }

    private func startMicrophone(turn: UUID) async throws {
        let continuation = audio
        let recordingURL = activeVisit.map { visits.audioURL($0) }
        try await microphone.start(recordingURL: recordingURL, onRecordingError: { [weak self] in
            Task { @MainActor in self?.fail("The recording couldn’t be saved. Please check device storage.") }
        }) { [weak self] data, bass, treble in
            let result = continuation?.yield(data)
            Task { @MainActor in
                guard let self, self.generation == turn, self.phase == .listening || self.activeVisit != nil else { return }
                if case .dropped? = result {
                    if self.activeVisit != nil {
                        self.markTranscriptIssue("The live transcript may have gaps because the connection fell behind. The local audio recording continues.")
                    } else {
                        self.fail("The connection isn’t keeping up with your voice. Please try again.")
                        return
                    }
                }
                self.bass = self.bass * 0.55 + CGFloat(bass) * 0.45
                self.treble = self.treble * 0.55 + CGFloat(treble) * 0.45
            }
        }
    }

    private func markTranscriptIssue(_ message: String) {
        guard var visit = activeVisit, visit.transcriptionIssue != message else { return }
        visit.transcriptionIssue = message
        activeVisit = visit
        do { try visits.save(visit) }
        catch { fail("Couldn’t save the transcript. Please check device storage.") }
    }

    private func speechFailed(_ message: String) {
        if activeVisit != nil, isRecordingVisit {
            stopCapture(keepRecording: true)
            markTranscriptIssue("Live transcription stopped: " + message + " The audio is still recording on this device.")
            phase = .listening
        } else { fail(message) }
    }

    /// During live conversation the circle pauses/resumes the microphone.
    func finishTurn() {
        guard let conversation else { return }
        let turn = generation
        Task {
            do { try await conversation.toggleMute() }
            catch { if generation == turn { fail("Couldn’t change the microphone. Please reconnect.") } }
        }
    }

    func interruptReply() {
        guard let conversation else { return }
        // Silence local playout immediately while the provider processes the interruption.
        conversation.agentAudioTrack?.volume = 0
        phase = .listening
        let turn = generation
        Task {
            do { try await conversation.interruptAgent() }
            catch { if generation == turn { fail("The conversation was interrupted. Please reconnect.") } }
        }
    }

    private func connectElevenLabs(turn: UUID) async {
        phase = .connecting
        do {
            await voiceShutdown?.value
            guard generation == turn, !Task.isCancelled else { return }
            let permission = await AVAudioApplication.requestRecordPermission()
            guard generation == turn, !Task.isCancelled else { return }
            guard permission else { throw ConnectionError.message("Allow microphone access in Settings to talk with Encircle.") }
            struct VoiceSession: Decodable { let token: String }
            let data: Data
            if let context = visits.cloudContext {
                data = try await VisitCloudClient(token: context.token).session("voice", circle: context.circleID)
            } else { data = try await api.request("voice/session", post: true) }
            let session = try JSONDecoder().decode(VoiceSession.self, from: data)
            guard generation == turn, !Task.isCancelled else { return }
            ElevenLabs.configure(.init(logLevel: .error, debugMode: false))
            #if targetEnvironment(simulator)
            // Simulator audio cannot reliably create the hardware voice-processing unit.
            // Keep native echo processing enabled on physical iPhones.
            try AudioManager.shared.setPlatformVoiceProcessingAllowed(false)
            #endif
            let config = ConversationConfig(
                audioConfiguration: .init(recordingAlwaysPrepared: true),
                onAgentResponse: { [weak self] text, _ in
                    Task { @MainActor in
                        guard let self, self.generation == turn else { return }
                        self.reply = SpokenText.clean(text)
                    }
                },
                onAgentResponseCorrection: { [weak self] _, corrected, _ in
                    Task { @MainActor in
                        guard let self, self.generation == turn else { return }
                        self.reply = SpokenText.clean(corrected)
                    }
                },
                onUserTranscript: { [weak self] text, _ in
                    Task { @MainActor in
                        guard let self, self.generation == turn else { return }
                        self.transcript = text
                        if VisitCommand.isStart(text) { self.startVisit() }
                        else if self.phase != .speaking { self.phase = .thinking }
                    }
                }
            )
            let connected = try await ElevenLabs.startConversation(conversationToken: session.token, config: config)
            guard generation == turn, !Task.isCancelled else { await connected.endConversation(); return }
            conversation = connected
            connected.agentAudioTrack?.volume = agentPlaybackVolume
            phase = .listening
            audioIsBeingSent = true
            let meter = ConversationMeter { [weak self] bass, treble in
                Task { @MainActor in
                    guard let self, self.generation == turn, !self.isMuted else { return }
                    self.bass = self.bass * 0.55 + CGFloat(bass) * 0.45
                    self.treble = self.treble * 0.55 + CGFloat(treble) * 0.45
                }
            }
            inputMeter = meter
            connected.inputTrack?.add(audioRenderer: meter)
            connected.$agentState.sink { [weak self] state in
                guard let self, self.generation == turn else { return }
                self.phase = state == .speaking ? .speaking : .listening
                self.conversation?.agentAudioTrack?.volume = self.agentPlaybackVolume
            }.store(in: &subscriptions)
            connected.$isMuted.sink { [weak self] muted in
                guard let self, self.generation == turn else { return }
                self.isMuted = muted; self.audioIsBeingSent = !muted
                if muted { self.bass = 0; self.treble = 0 }
            }.store(in: &subscriptions)
            connected.$state.sink { [weak self] state in
                guard let self, self.generation == turn else { return }
                switch state {
                case .error: self.fail("ElevenLabs voice couldn’t continue. Please try again.")
                case .ended: self.end()
                default: break
                }
            }.store(in: &subscriptions)
            connected.$pendingToolCalls.sink { [weak self] calls in
                guard let self, self.generation == turn else { return }
                for call in calls where self.handledTools.insert(call.toolCallId).inserted {
                    Task { await self.handleTool(call, turn: turn) }
                }
            }.store(in: &subscriptions)
            #if DEBUG
            // Live integration test: exercise the real provider tool through its text-input API.
            if ProcessInfo.processInfo.arguments.contains("--test-visit-tool") {
                try await connected.sendMessage("Please start recording my doctor visit now.")
            }
            #endif
        } catch {
            guard generation == turn, !Task.isCancelled else { return }
            try? await AudioManager.shared.setRecordingAlwaysPreparedMode(false)
            #if DEBUG
            let diagnostic = error.localizedDescription
                .replacingOccurrences(of: #"(?:https?|wss)://[^\s]+"#, with: "[endpoint]", options: .regularExpression)
                .replacingOccurrences(of: #"[A-Za-z0-9_=-]{32,}"#, with: "[redacted]", options: .regularExpression)
            UserDefaults.standard.set(String(diagnostic.prefix(400)), forKey: "encircleVoiceStartupDiagnostic")
            #endif
            // SDK errors can contain transport details; do not display or log tokens.
            if let connectionError = error as? ConnectionError { fail(connectionError.localizedDescription) }
            else { fail("Couldn’t connect to ElevenLabs voice. Please try again.") }
        }
    }

    private func handleTool(_ call: ClientToolCallEvent, turn: UUID) async {
        guard generation == turn, let conversation else { return }
        guard call.toolName == "start_visit_recording" else {
            if call.expectsResponse { try? await conversation.sendToolResult(for: call.toolCallId, result: "This action is unavailable.", isError: true) }
            else { conversation.markToolCallCompleted(call.toolCallId) }
            return
        }
        // Start the actual recorder; never allow a model-only confirmation to stand in for it.
        startVisit()
    }

    private func stopElevenLabs() {
        subscriptions.removeAll()
        if let meter = inputMeter { conversation?.inputTrack?.remove(audioRenderer: meter) }
        inputMeter = nil
        if let ending = conversation {
            conversation = nil
            voiceShutdown = Task {
                await ending.endConversation()
                try? await AudioManager.shared.setRecordingAlwaysPreparedMode(false)
            }
        }
        handledTools = []; isMuted = false
    }

    func startVisit() {
        guard activeVisit == nil else { return }
        guard visits.cloudRecordingAllowed else {
            end(); notice = "Sign in and choose a circle in Your account before recording. Everyone in that circle will be able to view the visit."
            return
        }
        end()
        var visit = SavedVisit(id: UUID(), date: Date())
        if let context = visits.cloudContext {
            visit.circleID = context.circleID; visit.creatorID = context.userID; visit.cloudPending = true
        }
        do { try visits.save(visit) }
        catch { notice = "Couldn’t start recording. Please check device storage."; return }
        activeVisit = visit
        UIApplication.shared.isIdleTimerDisabled = true
        notice = nil
        generation = UUID()
        let turn = generation
        phase = .connecting
        task = Task {
            do {
                await voiceShutdown?.value
                guard generation == turn, !Task.isCancelled else { return }
                let permission = await AVAudioApplication.requestRecordPermission()
                guard generation == turn, !Task.isCancelled else { return }
                guard permission else { throw ConnectionError.message("Allow microphone access in Settings to record a visit.") }
                visitStream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(64)) { continuation in audio = continuation }
                try await startMicrophone(turn: turn)
                guard generation == turn, !Task.isCancelled else { microphone.stop(); return }
                isRecordingVisit = true
                await transcribeVisit(turn: turn)
            } catch { if generation == turn, !Task.isCancelled { fail(error.localizedDescription) } }
        }
    }

    func finishVisit(interrupted: Bool = false, message: String? = nil) {
        guard activeVisit != nil, !finishingVisit else { return }
        finishingVisit = true
        if !interrupted, let id = activeVisit?.id {
            activeVisit?.transportRequestedAt = Date()
            visits.requestPresentationTransport(id)
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "Save visit")
        let turn = generation
        // Keep receiving briefly so Oracle can finalize the last words before saving.
        finalizer?.cancel()
        finalizer = Task {
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
            if !interrupted, let socket {
                try? await socket.send(.string("{\"event\":\"SEND_FINAL_RESULT\"}"))
                try? await Task.sleep(for: .milliseconds(1500))
            }
            guard generation == turn, var visit = activeVisit else { return }
            visit.duration = Date().timeIntervalSince(visit.date)
            visit.complete = !interrupted
            visit.finalized = true
            stopCapture()
            // Wait for the microphone queue to close the audio file before exposing playback.
            try? await AudioWork.run {}
            do {
                try visits.save(visit)
                activeVisit = nil; finishingVisit = false; isRecordingVisit = false; visitStream = nil
                end()
                notice = message
                if !visit.transcriptText.isEmpty { visits.summarize(visit.id) }
            } catch {
                finishingVisit = false
                self.error = "Couldn’t save the visit. Free some storage, then tap Finish to retry."
                phase = .failed
            }
        }
    }

    private func stopCapture(keepRecording: Bool = false) {
        audioIsBeingSent = false
        if !keepRecording { microphone.stop(); isRecordingVisit = false }
        audio?.finish(); audio = nil
        sender?.cancel(); sender = nil
        timeout?.cancel(); timeout = nil
        captureTimeout?.cancel(); captureTimeout = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        socketSession?.invalidateAndCancel(); socketSession = nil
        bass = 0; treble = 0
    }

    private func fail(_ message: String) {
        if activeVisit != nil { finishVisit(interrupted: true, message: message); return }
        stopCapture()
        stopElevenLabs()
        error = message
        phase = .failed
        AudioWork.deactivate()
    }

    func end() {
        if activeVisit != nil { finishVisit(interrupted: true, message: "Recording stopped when the app or audio session was interrupted. The captured visit is in Saved visits."); return }
        generation = UUID()
        task?.cancel(); task = nil
        finalizer?.cancel(); finalizer = nil
        stopCapture()
        stopElevenLabs()
        phase = .idle
        transcript = ""
        reply = ""
        error = nil
        AudioWork.deactivate()
    }
}


private final class ConversationMeter: NSObject, AudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var bands = VoiceBands()
    private var frames = 0
    private let deliver: @Sendable (Float, Float) -> Void
    init(deliver: @escaping @Sendable (Float, Float) -> Void) { self.deliver = deliver }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let count = Int(pcmBuffer.frameLength)
        guard count > 0 else { return }
        lock.lock()
        let levels: (Float, Float)
        if let samples = pcmBuffer.floatChannelData?[0] {
            levels = bands.levels(samples: UnsafeBufferPointer(start: samples, count: count), sampleRate: pcmBuffer.format.sampleRate)
        } else if let samples = pcmBuffer.int16ChannelData?[0] {
            let stride = pcmBuffer.format.isInterleaved ? Int(pcmBuffer.format.channelCount) : 1
            let normalized = (0..<count).map { Float(samples[$0 * stride]) / 32768 }
            levels = normalized.withUnsafeBufferPointer { bands.levels(samples: $0, sampleRate: pcmBuffer.format.sampleRate) }
        } else { lock.unlock(); return }
        frames += count
        let publish = frames >= Int(pcmBuffer.format.sampleRate / 25)
        if publish { frames = 0 }
        lock.unlock()
        if publish { deliver(levels.0, levels.1) }
    }
}
