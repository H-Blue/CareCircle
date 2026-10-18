import SwiftUI
import EventKit

struct ScheduledAppointment: Codable, Identifiable {
    let id: String
    let title: String
    let status: String
    let start: Date
    let end: Date
    let timeZone: String
    let isTestData: Bool
    var coordination: AppointmentCoordination?
    var dateLabel: String {
        start.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: TimeZone(identifier: timeZone)!))
    }
    var timeLabel: String {
        let format = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: TimeZone(identifier: timeZone)!)
        return start.formatted(format) + " – " + end.formatted(format)
    }
    enum CodingKeys: String, CodingKey {
        case id, title, status, start, end, coordination
        case timeZone = "time_zone", isTestData = "is_test_data"
    }
}

struct CoordinatedRide: Codable {
    let state: String
    let driver: String?
    let notTaking: [String]?
    enum CodingKeys: String, CodingKey { case state, driver; case notTaking = "not_taking" }
    var label: String {
        if let driver { return state == "confirmed" ? "Confirmed: " + driver : "Check arrangement with " + driver }
        switch state {
        case "awaiting_reply": return "Waiting for a reply"
        case "request_queued": return "Request queued"
        case "needs_attention": return "Leader follow-up needed"
        case "needs_review": return "Please review delivery or coverage"
        default: return "Not assigned"
        }
    }
}

struct AppointmentCoordination: Codable {
    let outbound: CoordinatedRide
    let `return`: CoordinatedRide
    var notes: String {
        "Cloud transport plan\nTo appointment: " + outbound.label +
        "\nNot taking outbound: " + ((outbound.notTaking ?? []).isEmpty ? "None recorded" : outbound.notTaking!.joined(separator: ", ")) +
        "\nRide home: " + self.return.label +
        "\nNot taking return: " + ((self.return.notTaking ?? []).isEmpty ? "None recorded" : self.return.notTaking!.joined(separator: ", "))
    }
}

struct ScheduleFeed: Codable {
    let patientID: String
    let isTestData: Bool
    let appointments: [ScheduledAppointment]
    enum CodingKeys: String, CodingKey {
        case patientID = "patient_id", isTestData = "is_test_data", appointments
    }
}

struct TransportPlan: Codable {
    var taking = ""
    var notTaking = ""

    func validate() throws {
        func names(_ value: String) -> Set<String> {
            Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        }
        guard names(taking).isDisjoint(with: names(notTaking)) else {
            throw ConnectionError.message("A person can’t be both taking and not taking this appointment. Please update the names.")
        }
    }

    func notes(recipient: String, demo: Bool) -> String {
        let taking = taking.trimmingCharacters(in: .whitespacesAndNewlines)
        let unavailable = notTaking.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Care recipient: \(recipient)\nTransport: \(taking.isEmpty ? "Not assigned" : "Assigned")\nTaking: \(taking.isEmpty ? "Not assigned" : taking)\nNot taking: \(unavailable.isEmpty ? "Not recorded" : unavailable)" + (demo ? "\nDemo appointment — synthetic scheduling data." : "")
    }
}

private struct CalendarPreferences: Codable {
    var recipient = ""
    var calendarID = ""
    var enabled = false
    var patientID: String?
    var eventIDs: [String: String] = [:]
    var transport: [String: TransportPlan] = [:]
    var feed: ScheduleFeed?
}

@MainActor
final class CareCalendarStore: ObservableObject {
    @Published private(set) var appointments: [ScheduledAppointment] = []
    @Published private(set) var writableCalendars: [EKCalendar] = []
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private var preferences = CalendarPreferences()
    private let events = EKEventStore()
    private let file: URL
    private var observer: NSObjectProtocol?
    var enabled: Bool { preferences.enabled }
    var recipient: String { preferences.recipient }
    var calendarID: String { preferences.calendarID }
    var isDemo: Bool { preferences.feed?.isTestData ?? true }
    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CalendarConnection", isDirectory: true)
        file = folder.appendingPathComponent("preferences.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            var location = folder
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try location.setResourceValues(values)
            if FileManager.default.fileExists(atPath: file.path) {
                preferences = try JSONDecoder().decode(CalendarPreferences.self, from: Data(contentsOf: file))
                appointments = preferences.feed?.appointments ?? []
            }
        } catch { self.error = "Calendar settings couldn’t be opened. Your existing data has been kept." }
        updateCalendars()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: events, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateCalendars() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func persist() throws {
        try JSONEncoder().encode(preferences).write(to: file, options: [.atomic, .completeFileProtection])
    }

    private func updateCalendars() {
        writableCalendars = hasAccess ? events.calendars(for: .event).filter(\.allowsContentModifications) : []
    }

    func plan(for appointment: ScheduledAppointment) -> TransportPlan {
        preferences.transport[appointment.id] ?? TransportPlan()
    }

    private func transportNotes(for appointment: ScheduledAppointment) -> String {
        let local = plan(for: appointment)
        guard let cloud = appointment.coordination else {
            return local.notes(recipient: preferences.recipient, demo: appointment.isTestData)
        }
        var text = "Care recipient: \(preferences.recipient)\n" + cloud.notes
        if !local.taking.isEmpty || !local.notTaking.isEmpty {
            text += "\nLocal notes (separate from SMS confirmations)\nTaking: \(local.taking.isEmpty ? "Not recorded" : local.taking)\nNot taking: \(local.notTaking.isEmpty ? "Not recorded" : local.notTaking)"
        }
        if appointment.isTestData { text += "\nDemo appointment — synthetic scheduling data; confirmations may be simulated." }
        return text
    }

    func load() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await fetchFeed() }
        catch { self.error = error.localizedDescription }
        updateCalendars()
    }

    private func fetchFeed() async throws {
        let api = EncircleAPI(address: UserDefaults.standard.string(forKey: "encircleServerAddress") ?? "", token: ConnectionToken.read())
        let data = try await api.request("appointments")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let feed = try decoder.decode(ScheduleFeed.self, from: data)
        guard !feed.patientID.isEmpty, Set(feed.appointments.map(\.id)).count == feed.appointments.count,
              feed.appointments.allSatisfy({ !$0.id.isEmpty && $0.end > $0.start && TimeZone(identifier: $0.timeZone) != nil }) else {
            throw ConnectionError.message("The scheduling feed contains invalid appointment details.")
        }
        if let patient = preferences.patientID, patient != feed.patientID {
            throw ConnectionError.message("The scheduling feed changed care recipients. Keep this calendar connection separate from the new recipient.")
        }
        preferences.patientID = feed.patientID
        preferences.feed = feed
        try persist()
        appointments = feed.appointments.sorted { $0.start < $1.start }
    }

    func connect(recipient: String, calendarID: String) async {
        guard !busy else { return }
        busy = true; error = nil; status = nil
        defer { busy = false }
        do {
            let name = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ConnectionError.message("Enter the name of the person you care for first.") }
            let granted = hasAccess ? true : try await events.requestFullAccessToEvents()
            guard granted else { throw ConnectionError.message("Allow full Calendar access in iPhone Settings to add and update your Encircle appointments.") }
            updateCalendars()
            let chosen = calendarID.isEmpty ? events.defaultCalendarForNewEvents?.calendarIdentifier : calendarID
            guard let chosen, writableCalendars.contains(where: { $0.calendarIdentifier == chosen }) else {
                throw ConnectionError.message("Choose a writable calendar. If none is available, add an account in Apple Calendar first.")
            }
            preferences.recipient = name
            preferences.calendarID = chosen
            // Save consent before creating events so interrupted syncs can safely resume.
            preferences.enabled = true
            try persist()
            try await fetchFeed()
            try syncEvents()
        } catch { self.error = error.localizedDescription }
    }

    func refreshIfEnabled() async {
        guard enabled, !busy else { return }
        busy = true; error = nil; status = nil
        defer { busy = false }
        do {
            guard hasAccess else { throw ConnectionError.message("Calendar access is off. Reconnect in Apple Calendar & transport.") }
            try await fetchFeed()
            try syncEvents()
        } catch { self.error = error.localizedDescription }
    }

    func savePlan(_ plan: TransportPlan, for appointment: ScheduledAppointment) async {
        guard !busy else { return }
        error = nil; status = nil
        do {
            try plan.validate()
            preferences.transport[appointment.id] = plan
            try persist()
            if enabled { await refreshIfEnabled() }
            else { status = "Transport details saved. Connect Apple Calendar to include them in event notes." }
        } catch { self.error = error.localizedDescription }
    }

    func disconnect() {
        preferences.enabled = false
        do { try persist(); status = "Automatic updates paused. Existing calendar events are kept." }
        catch { self.error = "Couldn’t save the calendar setting. Please try again." }
    }

    private func marker(for appointment: ScheduledAppointment) -> URL {
        var components = URLComponents()
        components.scheme = "encircle"; components.host = "appointment"
        components.path = "/" + (preferences.patientID ?? "") + "/" + appointment.id
        return components.url!
    }

    private func syncEvents() throws {
        guard hasAccess, let calendar = events.calendar(withIdentifier: preferences.calendarID), calendar.allowsContentModifications else {
            throw ConnectionError.message("The selected calendar is unavailable or read-only. Choose another calendar and reconnect.")
        }
        var count = 0
        for appointment in appointments {
            guard appointment.status == "booked" else { continue }
            let marker = marker(for: appointment)
            func matchesMarker(_ url: URL?) -> Bool {
                guard let url else { return false }
                return ["encircle", "carecircle"].contains(url.scheme ?? "") && url.host == marker.host && url.path == marker.path
            }
            let existing = preferences.eventIDs[appointment.id].flatMap { events.event(withIdentifier: $0) }
            let event: EKEvent
            if let existing, matchesMarker(existing.url) { event = existing }
            else {
                // EventKit identifiers can change after account sync. Search only our URL marker.
                let predicate = events.predicateForEvents(withStart: appointment.start.addingTimeInterval(-366 * 86400), end: appointment.end.addingTimeInterval(366 * 86400), calendars: [calendar])
                event = events.events(matching: predicate).first { matchesMarker($0.url) } ?? EKEvent(eventStore: events)
            }
            event.calendar = calendar
            event.title = preferences.recipient + " — Appointment" + (appointment.isTestData ? " (Demo)" : "")
            event.startDate = appointment.start; event.endDate = appointment.end
            event.timeZone = TimeZone(identifier: appointment.timeZone)
            event.url = marker
            let begin = "[Encircle]", end = "[/Encircle]"
            let block = begin + "\n" + transportNotes(for: appointment) + "\n" + end
            let previous = event.notes ?? ""
            let tags = previous.contains(begin) ? (begin, end) : ("[Care Circle]", "[/Care Circle]")
            if let first = previous.range(of: tags.0), let last = previous.range(of: tags.1, range: first.upperBound..<previous.endIndex) {
                event.notes = String(previous[..<first.lowerBound]) + block + String(previous[last.upperBound...])
            } else { event.notes = previous.isEmpty ? block : previous + "\n\n" + block }
            try events.save(event, span: .thisEvent, commit: true)
            preferences.eventIDs[appointment.id] = event.eventIdentifier
            try persist()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--test-calendar-sync") {
                precondition(events.events(matching: events.predicateForEvents(withStart: appointment.start.addingTimeInterval(-1), end: appointment.end.addingTimeInterval(1), calendars: [calendar])).filter { matchesMarker($0.url) }.count == 1)
                let stored = events.event(withIdentifier: event.eventIdentifier)
                precondition(stored?.notes?.contains(transportNotes(for: appointment)) == true)
                precondition(stored?.startDate == appointment.start && stored?.endDate == appointment.end)
            }
            #endif
            count += 1
        }
        status = "\(count) appointments updated in \(calendar.title)."
        updateCalendars()
    }
}

struct CalendarIntegrationView: View {
    @ObservedObject var store: CareCalendarStore
    @State private var recipient = ""
    @State private var calendarID = ""

    var body: some View {
        Form {
            Section {
                NavigationLink("Care coordinator") { CareCoordinatorView(calendar: store) }
                NavigationLink("SMS consent & preferences") { SMSConsentView() }
            } footer: { Text("See requests, confirmed rides, and anything needing your attention.") }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Care recipient").font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: $recipient).accessibilityIdentifier("Care recipient name")
                }
                if store.hasAccess {
                    Picker("Save appointments to", selection: $calendarID) {
                        Text("Default calendar").tag("")
                        ForEach(store.writableCalendars, id: \.calendarIdentifier) { calendar in
                            Text(calendar.title + " · " + calendar.source.title).tag(calendar.calendarIdentifier)
                        }
                    }
                }
                Button(store.enabled ? "Save & sync calendar" : "Connect Apple Calendar") {
                    Task {
                        await store.connect(recipient: recipient, calendarID: calendarID)
                        calendarID = store.calendarID
                    }
                }.disabled(store.busy || recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if store.enabled {
                    Button("Pause calendar updates") { store.disconnect() }.disabled(store.busy)
                }
            } header: { Text("Apple Calendar") } footer: {
                Text("Allow Calendar access once to add appointments and keep transport notes updated without duplicates. Choose an iCloud calendar to see events on your other Apple devices. Event titles and notes follow that calendar’s sharing settings. Your other calendar events are not sent to Encircle’s server.")
            }
            if store.busy { ProgressView("Updating appointments…") }
            if let error = store.error { Text(error).foregroundStyle(.red) }
            if let status = store.status { Text(status).accessibilityIdentifier("Calendar sync status") }
            Section {
                ForEach(store.appointments) { appointment in
                    NavigationLink {
                        TransportPlanView(store: store, appointment: appointment)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(appointment.dateLabel)
                            Text(appointment.timeLabel)
                                .font(.caption).foregroundStyle(.secondary)
                            if let rides = appointment.coordination {
                                Text("To appointment: " + rides.outbound.label).font(.caption)
                                Text("Ride home: " + rides.return.label).font(.caption)
                            } else {
                                let plan = store.plan(for: appointment)
                                Text(plan.taking.isEmpty ? "Transport not assigned" : "Taking: " + plan.taking).font(.caption)
                            }
                        }
                    }.accessibilityIdentifier("scheduled-" + appointment.id)
                }
            } header: { Text(store.isDemo ? "Demo appointments · Chicago time" : "Upcoming appointments") } footer: {
                Text("Cloud confirmations are tracked separately for each direction. Local notes stay on this phone and in your selected calendar. Calendar notes refresh when Encircle is open; they don’t refresh while the app is closed.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.89, green: 0.85, blue: 0.74).ignoresSafeArea())
        .navigationTitle("Calendar & transport")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(red: 0.89, green: 0.85, blue: 0.74), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            recipient = store.recipient; calendarID = store.calendarID
            await store.load()
        }
    }
}

private struct TransportPlanView: View {
    @ObservedObject var store: CareCalendarStore
    let appointment: ScheduledAppointment
    @State private var plan = TransportPlan()
    var body: some View {
        Form {
            Section {
                Text(appointment.dateLabel)
                if let rides = appointment.coordination {
                    Text("To appointment: " + rides.outbound.label)
                    Text("Ride home: " + rides.return.label)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Taking").font(.caption).foregroundStyle(.secondary)
                    TextField("Names", text: $plan.taking).accessibilityIdentifier("Taking them")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Not taking").font(.caption).foregroundStyle(.secondary)
                    TextField("Names", text: $plan.notTaking).accessibilityIdentifier("Not taking them")
                }
            } header: { Text("Local transport notes") } footer: {
                Text("Separate multiple names with commas. These notes don’t change cloud confirmations or send invitations. Confirmed SMS arrangements appear above and in calendar notes.")
            }
            Button("Save transport details") { Task { await store.savePlan(plan, for: appointment) } }.disabled(store.busy)
            if let error = store.error { Text(error).foregroundStyle(.red) }
            if let status = store.status { Text(status).accessibilityIdentifier("Calendar sync status") }
        }
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.89, green: 0.85, blue: 0.74).ignoresSafeArea())
        .navigationTitle("Who’s taking them?")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { plan = store.plan(for: appointment) }
    }
}

private struct CoordinatorSnapshot: Decodable {
    let mode: String
    let patientName: String
    let smsApproved: Bool
    let appointments: [Appointment]
    let messages: [Message]
    enum CodingKeys: String, CodingKey {
        case mode, appointments, messages
        case patientName = "patient_name", smsApproved = "sms_approved"
    }
    struct Appointment: Decodable, Identifiable {
        let id: String
        let start: Date
        let trips: AppointmentCoordination
        let aiReview: Review?
        enum CodingKeys: String, CodingKey { case id, start, trips; case aiReview = "ai_review" }
    }
    struct Review: Decodable { let source: String; let note: String }
    struct Message: Decodable, Identifiable {
        let id: String
        let kind: String
        let state: String
        let body: String
        let code: String?
        let blockedReason: String?
        enum CodingKeys: String, CodingKey { case id, kind, state, body, code; case blockedReason = "blocked_reason" }
    }
}

private struct CareCoordinatorView: View {
    @ObservedObject var calendar: CareCalendarStore
    @State private var snapshot: CoordinatorSnapshot?
    @State private var previousData: Data?
    @State private var error: String?
    @State private var busy = false
    private let cream = Color(red: 0.89, green: 0.85, blue: 0.74)
    private var api: EncircleAPI {
        EncircleAPI(address: UserDefaults.standard.string(forKey: "encircleServerAddress") ?? "", token: ConnectionToken.read())
    }
    var body: some View {
        Form {
            if let snapshot {
                Section {
                    Text(snapshot.patientName).font(.title2)
                    NavigationLink("SMS consent & preferences") { SMSConsentView() }
                    Text(snapshot.mode == "live" ? "Coordinating by text" : snapshot.mode == "paused" ? "Coordination paused" : "Demo simulation · no texts sent")
                    if !snapshot.smsApproved {
                        Text("Waiting for Twilio sender approval and trial recipient verification. The authorized demo can activate automatically after both are ready.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Check for updates") { Task { await check() } }.disabled(busy)
                } footer: {
                    Text("The coordinator runs on Oracle while the app is closed. Each direction needs a separate confirmation. This demo can text only your approved number, up to 20 outgoing messages per day.")
                }
                ForEach(snapshot.appointments) { appointment in
                    Section {
                        Text("To appointment: " + appointment.trips.outbound.label)
                        Text("Ride home: " + appointment.trips.return.label)
                        if let review = appointment.aiReview {
                            Text(review.note).font(.footnote).foregroundStyle(.secondary)
                            Text("Initial review · " + review.source).font(.caption2).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(appointment.start.formatted(Date.FormatStyle(date: .long, time: .shortened, timeZone: TimeZone(identifier: "America/Chicago")!)))
                    }
                }
                Section {
                    ForEach(snapshot.messages.reversed()) { message in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(message.body).font(.callout)
                            Text(message.state == "simulated" ? "Simulated · no text sent" : message.state.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption).foregroundStyle(.secondary)
                            if let reason = message.blockedReason { Text(reason).font(.caption).foregroundStyle(.red) }
                            if snapshot.mode == "test", message.kind == "request", message.state == "simulated", let code = message.code {
                                HStack {
                                    Button("Simulate acceptance") { Task { await simulate(code, reply: "YES") } }
                                    Button("Simulate decline") { Task { await simulate(code, reply: "NO") } }
                                }.buttonStyle(.borderless).font(.caption).disabled(busy)
                            }
                        }
                    }
                } header: { Text("Recent messages") } footer: {
                    Text("A delivered message is not a confirmed ride. Vague replies, failed messages, and uncertain delivery require follow-up.")
                }
            } else { ProgressView("Loading coordinator…") }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .scrollContentBackground(.hidden)
        .background(cream.ignoresSafeArea())
        .navigationTitle("Care coordinator")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
    }
    private func load() async {
        do {
            let data = try await api.request("coordinator")
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            snapshot = try decoder.decode(CoordinatorSnapshot.self, from: data)
            error = nil
            if previousData != data {
                previousData = data
                await calendar.refreshIfEnabled()
            }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    private func check() async {
        busy = true; defer { busy = false }
        do { _ = try await api.request("coordinator/check", post: true); await load() }
        catch { self.error = error.localizedDescription }
    }
    private func simulate(_ code: String, reply: String) async {
        busy = true; defer { busy = false }
        do {
            let data = try await api.request("coordinator/simulate", payload: ["code": code, "reply": reply])
            struct Result: Decodable { let result: String }
            let result = try JSONDecoder().decode(Result.self, from: data).result
            await load()
            if !["confirmed", "declined"].contains(result) { error = "This demo request is no longer waiting for a reply. Current status: " + result.replacingOccurrences(of: "_", with: " ") }
        } catch { self.error = error.localizedDescription }
    }
}

private struct SMSConsentInfo: Decodable {
    let program: String
    let version: String
    let disclosure: String
    let checkboxLabel: String
    let privacyURL: URL
    let termsURL: URL
    let proofURL: URL
    let active: Bool
    let optedOutBySMS: Bool
    let receipt: Receipt?
    enum CodingKeys: String, CodingKey {
        case program, version, disclosure, active, receipt
        case checkboxLabel = "checkbox_label", privacyURL = "privacy_url", termsURL = "terms_url"
        case proofURL = "proof_url", optedOutBySMS = "opted_out_by_sms"
    }
    struct Receipt: Decodable {
        let id: String
        let phone: String
        let acceptedAt: String
        enum CodingKeys: String, CodingKey { case id, phone; case acceptedAt = "accepted_at" }
    }
}

struct SMSConsentView: View {
    @State private var info: SMSConsentInfo?
    @State private var name = ""
    @State private var phone = ""
    @State private var agreed = false
    @State private var busy = false
    @State private var error: String?
    @State private var status: String?
    @FocusState private var editing: String?
    private let cream = Color(red: 0.89, green: 0.85, blue: 0.74)
    private var api: EncircleAPI {
        EncircleAPI(address: UserDefaults.standard.string(forKey: "encircleServerAddress") ?? "", token: ConnectionToken.read())
    }
    var body: some View {
        Form {
            if let info {
                Section {
                    Text("Appointment & transport texts").font(.title3)
                    Text(info.disclosure).font(.callout).accessibilityIdentifier("SMS disclosure")
                    HStack {
                        Link("SMS Terms", destination: info.termsURL)
                        Spacer()
                        Link("Privacy Notice", destination: info.privacyURL)
                    }.font(.callout)
                }
                Section {
                    TextField("Your name", text: $name)
                        .textContentType(.name).focused($editing, equals: "name")
                        .submitLabel(.done).onSubmit { editing = nil }
                        .accessibilityIdentifier("SMS consent name")
                    TextField("Your mobile number", text: $phone)
                        .textContentType(.telephoneNumber).keyboardType(.phonePad)
                        .focused($editing, equals: "phone")
                        .accessibilityIdentifier("SMS consent phone")
                    Button {
                        agreed.toggle()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: agreed ? "checkmark.square.fill" : "square").font(.title3)
                            Text(info.checkboxLabel).foregroundStyle(.primary)
                        }.padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("SMS consent checkbox")
                    .accessibilityValue(agreed ? "Checked" : "Unchecked")
                    .accessibilityIdentifier("SMS consent checkbox")
                    Button("Save SMS consent") { Task { await submit(action: "accept") } }
                        .disabled(busy || !agreed || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("Save SMS consent")
                } footer: {
                    Text("Enter your own number, including its country code, such as +1 for the US. This developer demo supports the owner’s configured number. Your name, number, agreement, and time are saved privately. SMS still requires Twilio sender approval.")
                }
                if info.active, let receipt = info.receipt {
                    Section {
                        Text("SMS consent is saved for the number ending in " + String(receipt.phone.suffix(4)) + ".")
                        if info.optedOutBySMS {
                            Text("You previously texted STOP. To resume texts, send START to the Encircle sender. Saving this form does not clear an SMS opt-out.")
                        }
                        Button("Withdraw SMS consent", role: .destructive) { Task { await submit(action: "withdraw") } }.disabled(busy)
                    } footer: {
                        Text("Withdrawal prevents future queued texts. A message already submitted to the carrier may still arrive. Past ride confirmations remain available for review.")
                    }
                }
                if let status { Text(status).accessibilityIdentifier("SMS consent status") }
                if let error { Text(error).foregroundStyle(.red) }
                Section {
                    Link("View public signup documentation", destination: info.proofURL)
                } footer: { Text("The public page shows a blank example of this screen. Your consent record is private.") }
            } else {
                if let error { Text(error).foregroundStyle(.red) }
                Button("Load SMS preferences") { Task { await load() } }.disabled(busy)
                if busy { ProgressView("Loading SMS preferences…") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(cream.ignoresSafeArea())
        .navigationTitle("SMS consent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = nil } }
        }
        .task { await load() }
    }
    private func load() async {
        busy = true; defer { busy = false }
        do {
            let data = try await api.request("sms/consent")
            info = try JSONDecoder().decode(SMSConsentInfo.self, from: data)
            agreed = false; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func submit(action: String) async {
        guard let info else { return }
        editing = nil; busy = true; error = nil; status = nil
        defer { busy = false }
        do {
            let targetPhone = action == "withdraw" ? info.receipt?.phone ?? "" : phone
            let payload: [String: Any] = ["action": action, "name": name, "phone": targetPhone, "accepted": agreed, "version": info.version]
            let data = try await api.request("sms/consent", json: JSONSerialization.data(withJSONObject: payload))
            self.info = try JSONDecoder().decode(SMSConsentInfo.self, from: data)
            agreed = false
            status = action == "accept" ? "Your SMS consent is saved. Texts can begin once the sender is approved and your number is eligible." : "SMS consent withdrawn. Future queued texts are suppressed."
        } catch { self.error = error.localizedDescription }
    }
}
