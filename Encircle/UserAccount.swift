import SwiftUI
import Security

enum AccountCredential {
    private static var query: [String: Any] {
        var name = "phone-sign-in"
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--test-account-flow") { name = "test-phone-sign-in" }
        #endif
        return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.harryhutchins.encircle.user-session", kSecAttrAccount as String: name]
    }
    static func read() -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ token: String) throws {
        let value = Data(token.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = value
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ConnectionError.message("Couldn’t save your sign-in securely. Please try again.") }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

enum AccountServer {
    static var address: String {
        let configured = UserDefaults.standard.string(forKey: "encircleServerAddress") ?? ""
        var address = configured.isEmpty ? "https://i7z5l4w5pojyo73cx4e7qb3iom.apigateway.us-chicago-1.oci.customer-oci.com/v1" : configured
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--test-account-flow"),
           let testAddress = ProcessInfo.processInfo.environment["ENCIRCLE_ACCOUNT_TEST_ADDRESS"] { address = testAddress }
        #endif
        return address
    }
}

struct CircleMember: Decodable, Identifiable {
    let id: String
    let name: String
    let role: String
}

struct UserCircle: Decodable, Identifiable {
    let id: String
    let name: String
    let patient_name: String
    let role: String
    let members: [CircleMember]
    let invite_code: String?
}

struct AccountSnapshot: Decodable {
    struct User: Decodable { let id: String; let name: String; let phone: String }
    let user: User
    let circles: [UserCircle]
    let token: String?
}

private struct AccountRequestError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

@MainActor final class AccountStore: ObservableObject {
    @Published var snapshot: AccountSnapshot?
    @Published var busy = false
    @Published var error: String?
    @Published var challenge: String?
    @Published var signedIn = !AccountCredential.read().isEmpty
    private var token = AccountCredential.read()

    private func request(_ path: String, payload: [String: String]? = nil) async throws -> Data {
        let address = AccountServer.address
        var request = URLRequest(url: try EncircleAPI.validatedURL(address).appendingPathComponent(path))
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let payload {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)
        }
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectionError.message("Please try again.") }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String }
            throw AccountRequestError(status: http.statusCode,
                message: (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Accounts are temporarily unavailable. Please try again.")
        }
        return data
    }

    func refresh() async {
        guard signedIn, !busy else { return }
        busy = true; error = nil; defer { busy = false }
        do { snapshot = try JSONDecoder().decode(AccountSnapshot.self, from: await request("users/me")); CircleSelection.notify() }
        catch {
            if (error as? AccountRequestError)?.status == 401 { clear() }
            self.error = error.localizedDescription
        }
    }

    func sendCode(name: String, phone: String) async {
        guard !busy else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            struct Started: Decodable { let challenge: String }
            challenge = try JSONDecoder().decode(Started.self, from: await request("users/auth/start", payload: ["name": name, "phone": phone])).challenge
        } catch { self.error = error.localizedDescription }
    }

    func verify(code: String) async {
        guard let challenge, !busy else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let result = try JSONDecoder().decode(AccountSnapshot.self, from: await request("users/auth/check", payload: ["challenge": challenge, "code": code]))
            guard let token = result.token else { throw ConnectionError.message("Sign-in wasn’t completed. Please try again.") }
            try AccountCredential.save(token)
            self.token = token; snapshot = result; signedIn = true; self.challenge = nil
            CircleSelection.notify()
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult func save(_ path: String, _ payload: [String: String]) async -> Bool {
        guard !busy else { return false }
        busy = true; error = nil; defer { busy = false }
        do {
            snapshot = try JSONDecoder().decode(AccountSnapshot.self, from: await request(path, payload: payload))
            CircleSelection.notify()
            return true
        } catch {
            if (error as? AccountRequestError)?.status == 401 { clear() }
            self.error = error.localizedDescription
            return false
        }
    }

    func signOut() async {
        guard !busy else { return }
        busy = true; error = nil; defer { busy = false }
        do { _ = try await request("users/logout", payload: [:]); clear() }
        catch {
            if (error as? AccountRequestError)?.status == 401 { clear() }
            else { self.error = "Couldn’t sign out on the server. Please reconnect and try again." }
        }
    }
    private func clear() {
        AccountCredential.clear(); token = ""; signedIn = false; snapshot = nil; challenge = nil
        CircleSelection.notify()
    }
}

struct UserAccountView: View {
    @StateObject private var account = AccountStore()
    @State private var name = ""
    @State private var phone = ""
    @State private var code = ""
    @FocusState private var editing: String?

    var body: some View {
        Form {
            if !account.signedIn { signIn }
            else if let snapshot = account.snapshot {
                Section("Your account") {
                    Text(snapshot.user.name).font(.title2)
                    Text(snapshot.user.phone).foregroundStyle(.secondary)
                    NavigationLink("SMS consent & preferences") { SMSConsentView() }
                    NavigationLink("Edit your name") { EditAccountNameView(account: account, name: snapshot.user.name) }
                }
                Section("Your circles") {
                    ForEach(snapshot.circles) { circle in
                        NavigationLink {
                            UserCircleView(account: account, circleID: circle.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(circle.name)
                                Text("Caring for " + circle.patient_name + " · " + circle.role.capitalized)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if snapshot.circles.isEmpty { Text("Create a circle or join someone who has invited you.").foregroundStyle(.secondary) }
                    NavigationLink("Create a circle") { CircleSetupView(account: account, joining: false) }
                    NavigationLink("Join a circle") { CircleSetupView(account: account, joining: true) }
                }
                Button("Sign out", role: .destructive) { Task { await account.signOut() } }.disabled(account.busy)
            } else {
                Button("Load your account") { Task { await account.refresh() } }.disabled(account.busy)
            }
            if account.busy { ProgressView("Please wait…") }
            if let error = account.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("Account error") }
        }
        .scrollContentBackground(.hidden).background(CareStyle.cream.ignoresSafeArea())
        .navigationTitle("Your account").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = nil } } }
        .task { await account.refresh() }
        .onChange(of: account.signedIn) { _, signedIn in
            if !signedIn { name = ""; phone = ""; code = "" }
        }
    }

    @ViewBuilder private var signIn: some View {
        if account.challenge == nil {
            Section {
                Text("Your people, in one circle.").font(.title2)
                TextField("Your name", text: $name).textContentType(.name)
                    .focused($editing, equals: "name").accessibilityIdentifier("Account name")
                TextField("Mobile number", text: $phone).textContentType(.telephoneNumber).keyboardType(.phonePad)
                    .focused($editing, equals: "phone").accessibilityIdentifier("Account phone")
                Button("Text me a sign-in code") {
                    editing = nil
                    Task { await account.sendCode(name: name, phone: phone) }
                }.disabled(account.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phone.isEmpty)
            } footer: {
                Text("Use your own mobile number, including its country code. We’ll text a one-time code to verify it. This does not sign you up for appointment or transport messages. Message and data rates may apply.")
            }
        } else {
            Section {
                Text("Check your texts").font(.title2)
                Text("Enter the six-digit code sent to " + phone + ".")
                TextField("Six-digit code", text: $code).textContentType(.oneTimeCode).keyboardType(.numberPad)
                    .focused($editing, equals: "code").accessibilityIdentifier("Account verification code")
                Button("Sign in") { editing = nil; Task { await account.verify(code: code) } }
                    .disabled(account.busy || code.count != 6)
                Button("Use a different number or request a new code") {
                    account.challenge = nil; account.error = nil; code = ""
                }.disabled(account.busy)
            } footer: { Text("Codes expire after 10 minutes. Wait at least a minute before requesting another.") }
        }
    }
}

private struct EditAccountNameView: View {
    @ObservedObject var account: AccountStore
    @State var name: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            TextField("Your name", text: $name).textContentType(.name)
            Button("Save name") { Task { if await account.save("users/profile", ["name": name]) { dismiss() } } }
                .disabled(account.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let error = account.error { Text(error).foregroundStyle(.red) }
        }.scrollContentBackground(.hidden).background(CareStyle.cream.ignoresSafeArea()).navigationTitle("Your name")
    }
}

private struct CircleSetupView: View {
    @ObservedObject var account: AccountStore
    let joining: Bool
    @State private var name = ""
    @State private var patient = ""
    @State private var invitation = ""
    @State private var role = "family"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if joining {
                Section {
                    TextField("Invitation code", text: $invitation).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Picker("I’m joining as", selection: $role) { Text("Family").tag("family"); Text("Friend").tag("friend") }
                } footer: { Text("Ask the circle leader for their invitation code. Joining shares your name and role and gives you access to this circle’s recorded visits.") }
            } else {
                Section {
                    TextField("Circle name", text: $name)
                    TextField("Who are you caring for?", text: $patient)
                } footer: { Text("You’ll be the circle leader. After creating the circle, you can share its invitation code with family and friends.") }
            }
            Button(joining ? "Join circle" : "Create circle") {
                Task {
                    let payload = joining ? ["invite_code": invitation, "role": role] : ["name": name, "patient_name": patient]
                    if await account.save(joining ? "users/circles/join" : "users/circles/create", payload) { dismiss() }
                }
            }.disabled(account.busy || (joining ? invitation.isEmpty : name.isEmpty || patient.isEmpty))
            if account.busy { ProgressView() }
            if let error = account.error { Text(error).foregroundStyle(.red) }
        }.scrollContentBackground(.hidden).background(CareStyle.cream.ignoresSafeArea())
            .navigationTitle(joining ? "Join a circle" : "Create a circle")
    }
}

private struct UserCircleView: View {
    @ObservedObject var account: AccountStore
    let circleID: String
    @State private var copied = false
    @State private var replaceCode = false
    @State private var leave = false
    @State private var selectedCircleID = ""
    @Environment(\.dismiss) private var dismiss
    private var circle: UserCircle? { account.snapshot?.circles.first { $0.id == circleID } }

    var body: some View {
        Form {
            if let circle {
                Section { Text(circle.name).font(.title2); Text("Caring for " + circle.patient_name) }
                if let uid = account.snapshot?.user.id {
                    Section {
                        Button(selectedCircleID == circle.id ? "Selected for visit recordings" : "Use this circle for visit recordings") {
                            CircleSelection.select(circle.id, user: uid); selectedCircleID = circle.id
                        }
                        Text("New recordings, transcripts and summaries are shared with every member of this circle.").font(.footnote)
                    }
                }
                Section("People") {
                    ForEach(circle.members) { member in
                        HStack { Text(member.name); Spacer(); Text(member.role.capitalized).foregroundStyle(.secondary) }
                    }
                }
                if let invite = circle.invite_code {
                    Section {
                        Text(invite).font(.system(.body, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("Circle invitation code")
                        Button(copied ? "Invitation code copied" : "Copy invitation code") { UIPasteboard.general.string = invite; copied = true }
                        Button("Replace invitation code") { replaceCode = true }.disabled(account.busy)
                    } header: { Text("Invite family & friends") }
                    footer: { Text("Anyone with this code and a verified account can join and access the circle’s recorded visits. Share it only with people you trust. Replacing it prevents new joins with the old code; existing members stay.") }
                } else {
                    Button("Leave circle", role: .destructive) { leave = true }.disabled(account.busy)
                }
            }
            if let error = account.error { Text(error).foregroundStyle(.red) }
        }.scrollContentBackground(.hidden).background(CareStyle.cream.ignoresSafeArea()).navigationTitle("Your circle")
        .onAppear { if let uid = account.snapshot?.user.id { selectedCircleID = CircleSelection.selected(uid) ?? "" } }
        .confirmationDialog("Replace the invitation code?", isPresented: $replaceCode) {
            Button("Replace code") { Task { _ = await account.save("users/circles/rotate", ["circle_id": circleID]); copied = false } }
        }
        .confirmationDialog("Leave this circle?", isPresented: $leave, titleVisibility: .visible) {
            Button("Leave circle", role: .destructive) { Task { if await account.save("users/circles/leave", ["circle_id": circleID]) { dismiss() } } }
        }
        .refreshable { await account.refresh() }
    }
}
