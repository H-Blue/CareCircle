import SwiftUI
import CryptoKit
import AVFoundation

struct VisitCloudContext: Equatable {
    let userID: String
    let circleID: String
    let circleName: String
    let role: String
    let token: String
    var key: String { userID + "/" + circleID }
}

enum CircleSelection {
    static let changed = Notification.Name("EncircleAccountChanged")
    static func selected(_ uid: String) -> String? { UserDefaults.standard.string(forKey: "encircleActiveCircle_" + uid) }
    static func select(_ circle: String, user: String) {
        UserDefaults.standard.set(circle, forKey: "encircleActiveCircle_" + user)
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func notify() { NotificationCenter.default.post(name: changed, object: nil) }
}

struct CloudVisitRecord: Decodable {
    var visit: SavedVisit
    let circle_id: String
    let creator_id: String
    let revision: String
    let audio_ready: Bool
    let audio_sha: String?
    let audio_bytes: Int
    let audio_parts: Int
    let audio_error: String?
    let summary_pending: Bool

    func local() -> SavedVisit {
        var value = visit
        value.circleID = circle_id; value.creatorID = creator_id; value.cloudRevision = revision
        value.cloudAudioReady = audio_ready; value.cloudAudioSHA = audio_sha
        value.cloudAudioParts = audio_parts; value.cloudSummaryPending = summary_pending
        value.finalized = true; value.cloudPending = false
        return value
    }
}

struct VisitCloudError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

struct VisitCloudClient {
    let token: String
    let address: String
    init(token: String, address: String = AccountServer.address) { self.token = token; self.address = address }

    func request(_ path: String, fields: [String: String] = [:], json: Data? = nil, bytes: Data? = nil) async throws -> Data {
        let base = try EncircleAPI.validatedURL(address)
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !fields.isEmpty { components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: components.url!)
        req.timeoutInterval = 65; req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body = bytes ?? json {
            req.httpMethod = "POST"; req.httpBody = body
            req.setValue(bytes == nil ? "application/json" : "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ConnectionError.message("Please retry syncing this visit.") }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String }
            throw VisitCloudError(status: http.statusCode, message: (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Circle storage couldn’t be reached. The upload copy is still on this phone.")
        }
        return data
    }
    func post(_ path: String, _ payload: [String: Any]) async throws -> Data {
        try await request(path, json: JSONSerialization.data(withJSONObject: payload))
    }
    func detail(circle: String, visit: UUID) async throws -> CloudVisitRecord {
        try JSONDecoder().decode(CloudVisitRecord.self, from: await request("visits/detail", fields: ["circle_id": circle, "visit_id": visit.uuidString]))
    }
    func list(circle: String) async throws -> [CloudVisitRecord] {
        struct Page: Decodable { let visits: [CloudVisitRecord]; let next_cursor: String? }
        var result: [CloudVisitRecord] = []; var cursor: String?
        repeat {
            var fields = ["circle_id": circle]
            if let cursor { fields["cursor"] = cursor }
            let page = try JSONDecoder().decode(Page.self, from: await request("visits", fields: fields))
            result += page.visits; cursor = page.next_cursor
        } while cursor != nil
        return result
    }
    func save(_ visit: SavedVisit, circle: String) async throws -> CloudVisitRecord {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(visit))
        var payload: [String: Any] = ["circle_id": circle, "visit": object]
        if let revision = visit.cloudRevision { payload["revision"] = revision }
        return try JSONDecoder().decode(CloudVisitRecord.self, from: await post("visits/save", payload))
    }
    func summary(circle: String, visit: UUID) async throws {
        _ = try await post("visits/summary", ["circle_id": circle, "visit_id": visit.uuidString])
    }
    func session(_ kind: String, circle: String) async throws -> Data {
        try await post("visits/" + kind + "/session", ["circle_id": circle])
    }

    static func checksum(_ url: URL) throws -> (String, Int) {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(); var size = 0
        while let part = try file.read(upToCount: 1024 * 1024), !part.isEmpty { hash.update(data: part); size += part.count }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    static func uploadCopy(_ original: URL) async throws -> URL {
        let destination = original.appendingPathExtension("upload.m4a")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let temporary = original.appendingPathExtension(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: original), presetName: AVAssetExportPresetAppleM4A) else { return original }
        exporter.outputURL = temporary; exporter.outputFileType = .m4a
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { continuation.resume() }
        }
        try Task.checkCancellation()
        guard exporter.status == .completed else { return original }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temporary.path)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    func uploadAudio(_ url: URL, circle: String, visit: UUID, progress: @escaping @Sendable (String) async -> Void) async throws -> CloudVisitRecord {
        let (sha, size) = try await Task.detached(priority: .utility) { try Self.checksum(url) }.value
        struct Start: Decodable { let ready: Bool; let uploaded: [Int]; let chunk_size: Int }
        let payload: [String: Any] = ["circle_id": circle, "visit_id": visit.uuidString, "sha": sha, "bytes": size]
        let start = try JSONDecoder().decode(Start.self, from: await post("visits/audio/start", payload))
        if !start.ready {
            let uploaded = Set(start.uploaded)
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            let count = (size + start.chunk_size - 1) / start.chunk_size
            for index in 0..<count {
                try Task.checkCancellation()
                if uploaded.contains(index) { continue }
                try file.seek(toOffset: UInt64(index * start.chunk_size))
                let part = try file.read(upToCount: start.chunk_size) ?? Data()
                _ = try await request("visits/audio/part", fields: ["circle_id": circle, "visit_id": visit.uuidString, "sha": sha, "index": String(index)], bytes: part)
                await progress("Uploading recording · " + String(index + 1) + " of " + String(count))
            }
            _ = try await post("visits/audio/finish", payload)
            for _ in 0..<25 {
                try Task.checkCancellation()
                let result = try await detail(circle: circle, visit: visit)
                if result.audio_ready {
                    guard result.audio_sha == sha && result.audio_bytes == size else { throw ConnectionError.message("Cloud verification didn’t match. Your original recording is still on this phone.") }
                    return result
                }
                if let error = result.audio_error { throw ConnectionError.message(error) }
                await progress("Verifying the cloud recording…")
                try await Task.sleep(for: .seconds(2))
            }
            throw ConnectionError.message("The cloud is still verifying this recording. Keep the app open or return later to resume.")
        }
        let result = try await detail(circle: circle, visit: visit)
        guard result.audio_ready, result.audio_sha == sha, result.audio_bytes == size else { throw ConnectionError.message("Recording verification is incomplete. Your original is still on this phone.") }
        return result
    }

    func downloadAudio(_ record: SavedVisit, circle: String, destination: URL) async throws -> URL {
        let current = try await detail(circle: circle, visit: record.id)
        guard current.audio_ready, let expected = current.audio_sha else { throw ConnectionError.message("The recording is still uploading. Its transcript is already available.") }
        let temporary = destination.appendingPathExtension(UUID().uuidString + ".download")
        FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
        var hash = SHA256(); var size = 0; var fileExtension = "audio"
        for index in 0..<current.audio_parts {
            try Task.checkCancellation()
            let part = try await request("visits/audio/part", fields: ["circle_id": circle, "visit_id": record.id.uuidString, "index": String(index)])
            if index == 0 {
                if part.prefix(4) == Data("caff".utf8) { fileExtension = "caf" }
                else if part.count > 8 && part[4..<8] == Data("ftyp".utf8) { fileExtension = "m4a" }
            }
            try file.write(contentsOf: part); hash.update(data: part); size += part.count
        }
        try file.close()
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected && size == current.audio_bytes else { throw ConnectionError.message("This recording didn’t download completely. Please retry.") }
        let cache = destination.appendingPathExtension("playback." + fileExtension)
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        try FileManager.default.moveItem(at: temporary, to: cache)
        return cache
    }
}

extension VisitStore {
    var cloudRecordingAllowed: Bool { cloudContext != nil || localTesting }

    func refreshCloud() async {
        guard !localTesting else { return }
        if refreshingCloud { cloudRefreshRequested = true; return }
        refreshingCloud = true
        defer {
            refreshingCloud = false
            if cloudRefreshRequested { cloudRefreshRequested = false; Task { await refreshCloud() } }
        }
        let token = AccountCredential.read()
        if let context = cloudContext, context.token != token { switchScope(nil) }
        if token.isEmpty { switchScope(nil); return }
        let client = VisitCloudClient(token: token)
        do {
            let me = try JSONDecoder().decode(AccountSnapshot.self, from: await client.request("users/me"))
            guard token == AccountCredential.read() else { return }
            var selected = CircleSelection.selected(me.user.id)
            if me.circles.count == 1 {
                selected = me.circles[0].id
                UserDefaults.standard.set(selected, forKey: "encircleActiveCircle_" + me.user.id)
            }
            guard let circle = me.circles.first(where: { $0.id == selected }) else {
                switchScope(nil); storageError = "Choose a circle in Your account before recording or viewing shared visits."; return
            }
            let context = VisitCloudContext(userID: me.user.id, circleID: circle.id, circleName: circle.name, role: circle.role, token: token)
            if cloudContext != context { switchScope(context) }
            let records = try await client.list(circle: circle.id)
            guard cloudContext == context, token == AccountCredential.read() else { return }
            mergeCloud(records)
            if storageError?.hasPrefix("Circle visits couldn’t refresh.") == true { storageError = nil }
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--test-cloud-visit"),
               AccountServer.address.hasPrefix("http://127.0.0.1:"), me.user.name == "Demo Leader", visits.isEmpty {
                try seedSyntheticCloudVisit(context)
            }
            #endif
            if syncTask == nil { startCloudSync() }
        } catch {
            if (error as? VisitCloudError)?.status == 401 || (error as? VisitCloudError)?.status == 403 {
                switchScope(nil)
            }
            storageError = "Circle visits couldn’t refresh. " + error.localizedDescription
        }
    }

    func switchScope(_ context: VisitCloudContext?) {
        guard cloudContext != context || (context == nil && !visits.isEmpty) else { return }
        syncTask?.cancel(); syncTask = nil
        for task in summaryTasks.values { task.cancel() }
        summaryTasks.removeAll(); summarizing.removeAll()
        cloudContext = context; scopeKey = context?.key ?? "signed-out"
        visits = []; storageError = nil; cloudStatus = nil
        // A signed-out account must never display a previous account's cloud cache.
        guard let context else { return }
        folder = rootFolder.appendingPathComponent("CircleCache/" + context.key, isDirectory: true)
        do {
            try prepareFolder(folder)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            visits = try files.map {
                var visit = try JSONDecoder().decode(SavedVisit.self, from: Data(contentsOf: $0))
                if visit.creatorID == context.userID && visit.cloudPending == true && visit.finalized != true {
                    visit.complete = false; visit.finalized = true
                    visit.duration = max(visit.duration, visit.lines.last?.elapsed ?? 0)
                    visit.transcriptionIssue = visit.transcriptionIssue ?? "Recording stopped before Finish was tapped. The captured audio and text have been recovered."
                    try persist(visit)
                }
                return visit
            }.sorted { $0.date > $1.date }
        } catch { storageError = "The phone’s upload queue couldn’t be opened. Its files have been kept." }
    }

    func mergeCloud(_ records: [CloudVisitRecord]) {
        let remote = Dictionary(uniqueKeysWithValues: records.map { ($0.visit.id, $0) })
        let pending = visits.filter { $0.cloudPending == true || $0.finalized != true }
        var combined = records.map { $0.local() }
        for var visit in pending {
            if let record = remote[visit.id] {
                visit.summary = record.visit.summary; visit.summaryError = record.visit.summaryError
                visit.cloudRevision = record.revision; visit.cloudSummaryPending = record.summary_pending
            }
            combined.removeAll { $0.id == visit.id }; combined.append(visit)
        }
        visits = combined.sorted { $0.date > $1.date }
        for visit in visits { try? persist(visit) }
        let visible = Set(visits.map(\.id))
        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !visible.contains(id) { try? FileManager.default.removeItem(at: file) }
            }
        }
        summarizing = Set(visits.filter { $0.cloudSummaryPending == true }.map(\.id))
    }

    func startCloudSync() {
        guard syncTask == nil, let context = cloudContext,
              visits.contains(where: { $0.cloudPending == true && $0.finalized == true && $0.creatorID == context.userID }) else { return }
        let location = folder
        syncTask = Task {
            defer { if cloudContext == context { syncTask = nil; cloudStatus = nil } }
            let client = VisitCloudClient(token: context.token)
            for original in visits.filter({ $0.cloudPending == true && $0.finalized == true && $0.creatorID == context.userID }) {
                do {
                    try Task.checkCancellation()
                    guard cloudContext == context else { return }
                    cloudStatus = "Sharing visit with " + context.circleName + "…"
                    var visit = original
                    let record = try await (visit.cloudRevision == nil ? client.save(visit, circle: context.circleID) : client.detail(circle: context.circleID, visit: visit.id))
                    guard cloudContext == context else { return }
                    visit.cloudRevision = record.revision; visit.summary = record.visit.summary
                    try save(visit)
                    if !visit.transcriptText.isEmpty && record.visit.summary == nil && !record.summary_pending {
                        try? await client.summary(circle: context.circleID, visit: visit.id)
                    }
                    let audio = location.appendingPathComponent(visit.audioName)
                    var final = record
                    if FileManager.default.fileExists(atPath: audio.path) {
                        cloudStatus = "Preparing recording for upload…"
                        let upload = try await VisitCloudClient.uploadCopy(audio)
                        final = try await client.uploadAudio(upload, circle: context.circleID, visit: visit.id) { message in
                            await MainActor.run { if self.cloudContext == context { self.cloudStatus = message } }
                        }
                    }
                    if !FileManager.default.fileExists(atPath: audio.path) { final = try await client.detail(circle: context.circleID, visit: visit.id) }
                    try Task.checkCancellation()
                    guard cloudContext == context else { return }
                    var synced = final.local(); synced.archived = visit.archived
                    try save(synced)
                    // Remove the upload copy only after Oracle confirms its full checksum.
                    if final.audio_ready {
                        try? FileManager.default.removeItem(at: audio)
                        try? FileManager.default.removeItem(at: audio.appendingPathExtension("upload.m4a"))
                    }
                    storageError = nil
                } catch is CancellationError { return }
                catch {
                    guard cloudContext == context else { return }
                    storageError = "This visit is waiting to sync. Its upload copy is safe on this phone. " + error.localizedDescription
                    break
                }
            }
        }
    }

    func cloudArchive(_ visit: SavedVisit, archived: Bool) {
        guard let context = cloudContext else { return }
        Task {
            do {
                _ = try await VisitCloudClient(token: context.token).post("visits/archive", ["circle_id": context.circleID, "visit_id": visit.id.uuidString, "archived": archived])
                guard cloudContext == context else { return }
                var updated = visits.first { $0.id == visit.id } ?? visit
                updated.archived = archived; try save(updated)
            } catch { storageError = error.localizedDescription }
        }
    }

    func cloudDelete(_ visit: SavedVisit) {
        guard let context = cloudContext else { return }
        Task {
            do {
                _ = try await VisitCloudClient(token: context.token).post("visits/delete", ["circle_id": context.circleID, "visit_id": visit.id.uuidString])
                guard cloudContext == context else { return }
                removeLocal(visit)
            } catch { storageError = error.localizedDescription }
        }
    }

    func cloudSummarize(_ id: UUID) {
        guard let context = cloudContext else { return }
        Task {
            do {
                try await VisitCloudClient(token: context.token).summary(circle: context.circleID, visit: id)
                guard cloudContext == context else { return }
                summarizing.insert(id)
                await refreshCloud()
            } catch { storageError = error.localizedDescription }
        }
    }

    func prepareAudio(_ visit: SavedVisit) async throws -> URL {
        let destination = audioURL(visit)
        if let context = cloudContext {
            if visit.cloudPending == true && visit.creatorID == context.userID && FileManager.default.fileExists(atPath: destination.path) { return destination }
            let client = VisitCloudClient(token: context.token)
            // Recheck membership even when playback bytes are already cached.
            _ = try await client.detail(circle: context.circleID, visit: visit.id)
            guard cloudContext == context, AccountCredential.read() == context.token else { throw CancellationError() }
            for suffix in ["m4a", "caf", "audio"] {
                let cache = destination.appendingPathExtension("playback." + suffix)
                if FileManager.default.fileExists(atPath: cache.path) { return cache }
            }
            let cache = try await client.downloadAudio(visit, circle: context.circleID, destination: destination)
            guard cloudContext == context else { throw CancellationError() }
            return cache
        }
        return destination
    }

    #if DEBUG && targetEnvironment(simulator)
    private func seedSyntheticCloudVisit(_ context: VisitCloudContext) throws {
        var visit = SavedVisit(id: UUID(uuidString: "71E041CE-225E-42F7-91E3-A2ABC762AE01")!, date: Date(),
            lines: [VisitLine(text: "Clinician: Your scan shows no fracture. Please schedule a follow-up in two weeks.", elapsed: 0)], duration: 10, complete: true)
        visit.circleID = context.circleID; visit.creatorID = context.userID; visit.finalized = true; visit.cloudPending = true
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160000)!
        buffer.frameLength = 160000
        if let channel = buffer.floatChannelData?[0] {
            for sample in 0..<160000 { channel[sample] = Float(sin(Double(sample) * 2 * .pi * 220 / 16000) * 0.05) }
        }
        do {
            let file = try AVAudioFile(forWriting: audioURL(visit), settings: format.settings)
            try file.write(from: buffer)
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: audioURL(visit).path)
        try save(visit)
    }
    #endif

    var legacyVisits: [SavedVisit] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: legacyFolder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(SavedVisit.self, from: Data(contentsOf: $0)) }.sorted { $0.date > $1.date }
    }
    func importLegacy(_ old: SavedVisit) throws {
        guard let context = cloudContext else { throw ConnectionError.message("Sign in and choose a circle first.") }
        guard !visits.contains(where: { $0.id == old.id }) else { throw ConnectionError.message("This visit is already in this circle or its upload queue.") }
        var visit = old
        visit.circleID = context.circleID; visit.creatorID = context.userID; visit.finalized = true
        visit.cloudPending = true; visit.cloudRevision = nil
        let original = legacyFolder.appendingPathComponent(old.audioName)
        if FileManager.default.fileExists(atPath: original.path) { try FileManager.default.copyItem(at: original, to: audioURL(visit)) }
        try save(visit); startCloudSync()
    }
}

struct LegacyVisitImportView: View {
    @ObservedObject var store: VisitStore
    @State private var selected: SavedVisit?
    @State private var error: String?
    var body: some View {
        List {
            Text("Choose an older phone recording to share with " + (store.cloudContext?.circleName ?? "a circle") + ". Every member of that circle will be able to read its transcript and summary and play its recording. The original phone copy is preserved.").font(.callout)
            ForEach(store.legacyVisits) { visit in
                Button { selected = visit } label: {
                    Text(visit.date, format: .dateTime.month().day().year().hour().minute())
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.scrollContentBackground(.hidden).background(CareStyle.cream.ignoresSafeArea())
        .navigationTitle("Older phone recordings")
        .confirmationDialog("Share this recording with every member of " + (store.cloudContext?.circleName ?? "this circle") + "?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            Button("Share recording, transcript & summary") {
                if let selected { do { try store.importLegacy(selected); error = nil } catch { self.error = error.localizedDescription } }
                selected = nil
            }
        }
    }
}
