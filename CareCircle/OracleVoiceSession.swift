import Foundation
import UIKit
import AVFoundation
import Combine
import Dispatch

/// Audio route changes and engine setup may block; keep them off the UI thread.
private enum AudioWork {
    static let queue = DispatchQueue(label: "com.carecircle.audio-control")

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

    func start(deliver: @escaping (Data, Float, Float) -> Void) async throws {
        try await AudioWork.run { try self.startEngine(deliver: deliver) }
    }

    private func startEngine(deliver: @escaping (Data, Float, Float) -> Void) throws {
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
        var bands = VoiceBands()
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { buffer, _ in
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
        }
    }
}

@MainActor
final class OracleVoiceSession: NSObject, ObservableObject, AVAudioPlayerDelegate {
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
    private let microphone = MicrophoneCapture()
    private var socket: URLSessionWebSocketTask?
    private var socketSession: URLSession?
    private var task: Task<Void, Never>?
    private var finalizer: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var captureTimeout: Task<Void, Never>?
    private var audio: AsyncStream<Data>.Continuation?
    private var player: AVAudioPlayer?
    private var history: [ChatMessage] = []
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private var remainingSpeech: [String] = []
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

    private var api: CareCircleAPI {
        CareCircleAPI(address: UserDefaults.standard.string(forKey: "careCircleServerAddress") ?? "", token: ConnectionToken.read())
    }

    func begin() {
        end()
        error = nil
        reply = ""
        transcript = ""
        history = []
        generation = UUID()
        let turn = generation
        task = Task { await listen(turn: turn) }
    }

    private func listen(turn: UUID) async {
        guard generation == turn, !Task.isCancelled else { return }
        phase = .connecting
        transcript = ""
        do {
            let permission = await AVAudioApplication.requestRecordPermission()
            guard generation == turn, !Task.isCancelled else { return }
            guard permission else { throw ConnectionError.message("Allow microphone access in iPhone Settings to speak with Care Circle.") }
            struct Session: Decodable { let token: String; let compartmentId: String; let endpoint: String }
            let data = try await api.request("speech/session", post: true)
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
                URLQueryItem(name: "finalSilenceThresholdInMs", value: "1200"),
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
                self.fail("Oracle voice took too long to connect. Please try again.")
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
                            if result["isFinal"] as? Bool == true {
                                stopCapture()
                                await respond(text: text, turn: turn)
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
            fail(error.localizedDescription)
        }
    }

    private func capture(connection: URLSessionWebSocketTask, turn: UUID) async throws {
        guard phase == .connecting else { return }
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(64)) { continuation in audio = continuation }
        let continuation = audio
        try await microphone.start { [weak self] data, bass, treble in
            let result = continuation?.yield(data)
            Task { @MainActor in
                guard let self, self.generation == turn, self.phase == .listening else { return }
                if case .dropped? = result {
                    self.fail("The connection isn’t keeping up with your voice. Please try again.")
                    return
                }
                self.bass = self.bass * 0.55 + CGFloat(bass) * 0.45
                self.treble = self.treble * 0.55 + CGFloat(treble) * 0.45
            }
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
                if !Task.isCancelled, self?.generation == turn { self?.fail("The voice connection was interrupted. Please try again.") }
            }
        }
        captureTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, self.generation == turn else { return }
            self.fail("Listening paused after one minute. Tap the circle to continue.")
        }
    }

    func finishTurn() {
        guard phase == .listening, let socket else { return }
        let turn = generation
        finalizer = Task { [weak self] in
            do { try await socket.send(.string("{\"event\":\"SEND_FINAL_RESULT\"}")) }
            catch {
                guard !Task.isCancelled, self?.generation == turn else { return }
                self?.fail("Couldn’t finish this message. Please try again.")
            }
        }
    }

    private func respond(text: String, turn: UUID) async {
        guard generation == turn else { return }
        phase = .thinking
        do {
            let userMessage = ChatMessage(role: "user", content: text)
            let result = try await api.reply(to: Array(history.suffix(18)) + [userMessage])
            guard generation == turn, !Task.isCancelled else { return }
            history.append(userMessage)
            history.append(ChatMessage(role: "assistant", content: result))
            reply = result
            remainingSpeech = Self.speechSegments(result)
            try await speakNext(turn: turn)
        } catch {
            guard generation == turn, !Task.isCancelled else { return }
            fail(error.localizedDescription)
        }
    }

    static func speechSegments(_ text: String) -> [String] {
        var segments: [String] = []
        var current = ""
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            if current.count + word.count + 1 > 1900 && !current.isEmpty {
                segments.append(current)
                current = ""
            }
            // A model can return an unusually long unbroken word. Keep every request bounded.
            if word.count > 1900 {
                if !current.isEmpty { segments.append(current); current = "" }
                var rest = word[...]
                while !rest.isEmpty { segments.append(String(rest.prefix(1900))); rest = rest.dropFirst(min(rest.count, 1900)) }
            } else {
                current += (current.isEmpty ? "" : " ") + word
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private func speakNext(turn: UUID) async throws {
        guard !remainingSpeech.isEmpty else { return }
        phase = .thinking
        let text = remainingSpeech.removeFirst()
        let data = try await api.request("speech/synthesize", text: text)
        guard generation == turn, !Task.isCancelled else { return }
        try await AudioWork.run {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        }
        guard generation == turn, !Task.isCancelled else { return }
        let playback = try AVAudioPlayer(data: data)
        playback.delegate = self
        player = playback
        phase = .speaking
        guard playback.play() else { throw ConnectionError.message("The reply couldn’t play. You can read it above.") }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.phase == .speaking else { return }
            if flag {
                let turn = self.generation
                self.task = Task {
                    if self.remainingSpeech.isEmpty {
                        await self.listen(turn: turn)
                    } else {
                        do { try await self.speakNext(turn: turn) }
                        catch { if self.generation == turn { self.fail("The spoken reply couldn’t continue. You can read it above.") } }
                    }
                }
            } else { self.fail("The spoken reply was interrupted. Tap the circle to reconnect.") }
        }
    }

    private func stopCapture() {
        audioIsBeingSent = false
        microphone.stop()
        audio?.finish(); audio = nil
        sender?.cancel(); sender = nil
        timeout?.cancel(); timeout = nil
        captureTimeout?.cancel(); captureTimeout = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        socketSession?.invalidateAndCancel(); socketSession = nil
        bass = 0; treble = 0
    }

    private func fail(_ message: String) {
        stopCapture()
        player?.stop(); player = nil
        error = message
        phase = .failed
        AudioWork.deactivate()
    }

    func end() {
        generation = UUID()
        task?.cancel(); task = nil
        finalizer?.cancel(); finalizer = nil
        stopCapture()
        player?.stop(); player = nil
        phase = .idle
        history = []
        remainingSpeech = []
        transcript = ""
        reply = ""
        error = nil
        AudioWork.deactivate()
    }
}
