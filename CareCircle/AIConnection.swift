import SwiftUI
import Security

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
              !url.path.contains("..") else {
            throw ConnectionError.message("Enter your Care Circle server address, such as https://care.example.com.")
        }
        if url.scheme == "https" { return url }
        #if targetEnvironment(simulator)
        if url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host) { return url }
        #endif
        throw ConnectionError.message("Use an HTTPS server address to protect your conversations.")
    }

    func request(_ path: String, messages: [ChatMessage]? = nil, text: String? = nil, post: Bool = false) async throws -> Data {
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
        if post || text != nil {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: text.map { ["text": $0] } ?? [:])
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
                Text("Voice and messages are processed by Oracle Cloud while listening is active. End the session to stop the microphone. Ordinary conversations are not saved as visit recordings.")
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
