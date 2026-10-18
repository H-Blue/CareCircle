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
    var dateLabel: String {
        start.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: TimeZone(identifier: timeZone)!))
    }
    var timeLabel: String {
        let format = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: TimeZone(identifier: timeZone)!)
        return start.formatted(format) + " – " + end.formatted(format)
    }
    enum CodingKeys: String, CodingKey {
        case id, title, status, start, end
        case timeZone = "time_zone", isTestData = "is_test_data"
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

    func load() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await fetchFeed() }
        catch { self.error = error.localizedDescription }
        updateCalendars()
    }

    private func fetchFeed() async throws {
        let api = CareCircleAPI(address: UserDefaults.standard.string(forKey: "careCircleServerAddress") ?? "", token: ConnectionToken.read())
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
            guard granted else { throw ConnectionError.message("Allow full Calendar access in iPhone Settings to add and update your Care Circle appointments.") }
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
        components.scheme = "carecircle"; components.host = "appointment"
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
            let existing = preferences.eventIDs[appointment.id].flatMap { events.event(withIdentifier: $0) }
            let event: EKEvent
            if let existing, existing.url == marker { event = existing }
            else {
                // EventKit identifiers can change after account sync. Search only our URL marker.
                let predicate = events.predicateForEvents(withStart: appointment.start.addingTimeInterval(-366 * 86400), end: appointment.end.addingTimeInterval(366 * 86400), calendars: [calendar])
                event = events.events(matching: predicate).first { $0.url == marker } ?? EKEvent(eventStore: events)
            }
            event.calendar = calendar
            event.title = preferences.recipient + " — Appointment" + (appointment.isTestData ? " (Demo)" : "")
            event.startDate = appointment.start; event.endDate = appointment.end
            event.timeZone = TimeZone(identifier: appointment.timeZone)
            event.url = marker
            let begin = "[Care Circle]", end = "[/Care Circle]"
            let block = begin + "\n" + plan(for: appointment).notes(recipient: preferences.recipient, demo: appointment.isTestData) + "\n" + end
            let previous = event.notes ?? ""
            if let first = previous.range(of: begin), let last = previous.range(of: end, range: first.upperBound..<previous.endIndex) {
                event.notes = String(previous[..<first.lowerBound]) + block + String(previous[last.upperBound...])
            } else { event.notes = previous.isEmpty ? block : previous + "\n\n" + block }
            try events.save(event, span: .thisEvent, commit: true)
            preferences.eventIDs[appointment.id] = event.eventIdentifier
            try persist()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--test-calendar-sync") {
                precondition(events.events(matching: events.predicateForEvents(withStart: appointment.start.addingTimeInterval(-1), end: appointment.end.addingTimeInterval(1), calendars: [calendar])).filter { $0.url == marker }.count == 1)
                let stored = events.event(withIdentifier: event.eventIdentifier)
                precondition(stored?.notes?.contains(plan(for: appointment).notes(recipient: preferences.recipient, demo: appointment.isTestData)) == true)
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
                LabeledContent("Care recipient") {
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
                Text("Allow Calendar access once to add appointments and keep transport notes updated without duplicates. Choose an iCloud calendar to see events on your other Apple devices. Event titles and notes follow that calendar’s sharing settings. Your other calendar events are not sent to Care Circle’s server.")
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
                            let plan = store.plan(for: appointment)
                            Text(plan.taking.isEmpty ? "Transport not assigned" : "Taking: " + plan.taking).font(.caption)
                        }
                    }.accessibilityIdentifier("scheduled-" + appointment.id)
                }
            } header: { Text(store.isDemo ? "Demo appointments · Chicago time" : "Upcoming appointments") } footer: {
                Text("Tap an appointment to record who is taking them and who isn’t. Names stay on this phone and in your selected calendar; family members aren’t notified automatically.")
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
                LabeledContent("Taking") {
                    TextField("Names", text: $plan.taking).accessibilityIdentifier("Taking them")
                }
                LabeledContent("Not taking") {
                    TextField("Names", text: $plan.notTaking).accessibilityIdentifier("Not taking them")
                }
            } header: { Text("Transport") } footer: {
                Text("Separate multiple names with commas. Leave Taking blank if no one has agreed yet. Only enter confirmed arrangements; this doesn’t send invitations.")
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
