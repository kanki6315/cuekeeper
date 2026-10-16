#if DEBUG
import CoreData
import CloudKit
import SwiftUI
import WidgetKit

/// Synthetic review records, gated to the isolated UI-test store. Never used in a normal launch.
enum DesignFixtures {
    static var enabled: Bool { ProcessInfo.processInfo.isUITesting && ProcessInfo.processInfo.arguments.contains("--design-fixtures") }
    static var route: String { ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--design-screen=") })?.replacingOccurrences(of: "--design-screen=", with: "") ?? "root" }
    @MainActor static func seed(_ context: NSManagedObjectContext) throws {
        guard enabled, try context.count(for: NSFetchRequest<Job>(entityName: "Job")) == 0 else { return }
        if ProcessInfo.processInfo.arguments.contains("--today-fixtures") {
            try seedToday(context)
            return
        }
        let start = Calendar.current.startOfDay(for: Date())
        var created: [Job] = []
        for (index, name) in ["City vs United", "Studio highlights", "National finals", "Daytona", "Sebring AEC", "Season opener"].enumerated() {
            let day = start.addingTimeInterval(Double(index < 3 ? index : index + 2) * 86400)
            var draft = JobDraft(name: name, startDate: day, endDate: day.addingTimeInterval(index == 3 ? 2 * 86400 : 0))
            draft.clientName = index < 3 ? "Northside Sports" : "IMSA"
            draft.projectName = index < 3 ? "Autumn broadcasts" : "IMSA 2026"
            draft.seriesName = index < 3 ? "National League" : "SportsCar Championship"
            draft.roleNames = ["Commentator"]
            draft.bookingStatus = index == 1 || index == 3 ? .tentative : .booked
            draft.workArrangement = index == 0 || index == 1 ? .remote : .onSite
            draft.timeZoneID = "Europe/London"
            if index == 0 && ProcessInfo.processInfo.arguments.contains("--weather-fixtures") {
                draft.name = "Daytona race weekend"; draft.workArrangement = .onSite
                draft.trackPlaceID = "fixture-track"; draft.timeZoneID = "America/New_York"
                draft.startDate = start; draft.endDate = start.addingTimeInterval(86400)
            }
            draft.notes = "Programme notes and running order to follow. Check the final schedule with the producer."
            draft.fee?.currency = index == 4 ? "EUR" : "USD"
            draft.fee?.amount = ["1200", "450", "850", "2400", "900", "1500"][index]
            draft.fee?.agreement = "agreed"
            if index == 0 { draft.fee?.lines = [FeeLine(description: "Commentary", quantity: "1", rate: "1000"), FeeLine(description: "Preparation", quantity: "1", rate: "150")] }
            let id = try draft.save(in: context)
            created.append(try context.existingObject(with: id) as! Job)
        }
        if ["expense", "pending-expenses", "expense-notification", "pending-root", "expenses-overview"].contains(route) {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 700), format: format).image { renderer in
                UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 600, height: 700))
                let text = "CIRCUIT PARKING\n\n15 October 2026\n\nParking          EUR 20.00\nTax               EUR 4.50\nTOTAL            EUR 24.50\n\nPaid by card\n\nSYNTHETIC TEST RECEIPT"
                (text as NSString).draw(in: CGRect(x: 35, y: 45, width: 530, height: 620), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 24, weight: .regular), .foregroundColor: UIColor.black])
            }
            if route == "expense" {
                let id = try Expense.capture(image.jpegData(compressionQuality: 0.9)!, jobID: created[0].objectID, in: context)
                let expense = try context.existingObject(with: id) as! Expense
                try Expense.save(ExpenseValue(merchant: "Circuit Parking", day: "2026-10-15", amount: "24.50", currency: "EUR", tax: "4.50", category: "Parking"), id: id, revision: expense.revision, confirmed: false, in: context)
            } else {
                let captured = try Expense.captureBackground(ExpenseCaptureInput(merchant: "Circuit Parking", amount: "24.50", currency: "EUR", date: Day.date(from: "2026-10-15"), transactionID: "fixture-parking"), in: context)
                let expense = try context.existingObject(with: captured.objectID) as! Expense
                try Expense.replacePhoto(image.jpegData(compressionQuality: 0.9)!, id: expense.objectID, revision: expense.revision, in: context)
                _ = try Expense.captureBackground(ExpenseCaptureInput(merchant: "Hotel", amount: "120", currency: "EUR", transactionID: "fixture-hotel"), in: context)
            }
        }
        if route == "expenses-overview" {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { renderer in
                UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
                ("SYNTHETIC RECEIPT" as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.foregroundColor: UIColor.black])
            }
            for (index, merchant) in ["Trackside Cafe", "Rail Europe"].enumerated() {
                let id = try Expense.capture(image.jpegData(compressionQuality: 0.9)!, jobID: created[index].objectID, in: context)
                let expense = try context.existingObject(with: id) as! Expense
                try Expense.save(ExpenseValue(merchant: merchant, day: "2026-10-14", amount: index == 0 ? "18.50" : "86.00", currency: index == 0 ? "USD" : "EUR", category: index == 0 ? "Meals" : "Travel", reimbursable: index == 1), id: id, revision: expense.revision, in: context)
            }
        }
        if let client = created[0].client {
            let original = LibraryDraft(record: client)
            var contact = original; contact.contact = "Production desk · producer@northside.example"; contact.notes = "Send fee confirmations to the production desk."
            try contact.save(entity: "Client", editing: client.objectID, baseline: original, in: context)
        }
        var session = SessionDraft(job: created[0])
        session.name = "Live match"; session.timeZoneID = "Europe/London"
        session.startTime = Day.date(from: created[0].startDay, timeZone: TimeZone(identifier: session.timeZoneID)!)!.addingTimeInterval(19 * 3600 + 45 * 60)
        session.endTime = session.startTime!.addingTimeInterval(2 * 3600)
        session.callTime = session.startTime!.addingTimeInterval(-3600)
        if ProcessInfo.processInfo.arguments.contains("--weather-fixtures") {
            session.name = "Race coverage"; session.timeZoneID = "America/New_York"
            session.callTime = Date().addingTimeInterval(3600)
            session.startTime = Date().addingTimeInterval(7200)
            session.endTime = Date().addingTimeInterval(14400)
            session.day = Day.string(from: session.startTime!, timeZone: TimeZone(identifier: session.timeZoneID)!)
        }
        session.scheduleStatus = "confirmed"; session.coverage = "covering"
        try session.save(in: context, jobID: created[0].objectID)
        var invoice = InvoiceDraft(clientID: created[0].client!.id!, currency: "USD")
        invoice.value.reference = "INV-2026-042"; invoice.value.status = "sent"
        invoice.value.sentDay = Day.string(from: start.addingTimeInterval(-5 * 86400))
        invoice.value.dueDay = Day.string(from: start.addingTimeInterval(9 * 86400))
        invoice.value.lines = [BilledLine(jobID: created[0].id!, jobName: created[0].name, amount: 120000), BilledLine(jobID: created[2].id!, jobName: created[2].name, amount: 85000)]
        let invoiceID = try invoice.save(in: context)
        var payment = PaymentDraft(); payment.amount = "500"; payment.note = "Part payment"
        try payment.save(in: context, invoiceID: invoiceID)
        var second = InvoiceDraft(clientID: created[5].client!.id!, currency: "USD")
        second.value.reference = "INV-2026-043"; second.value.lines = [BilledLine(jobID: created[5].id!, jobName: created[5].name, amount: 150000)]
        try second.save(in: context)
        if DesignFixtures.route == "recently-deleted" {
            try Job.remove(created[0].objectID, in: context)
        }
        if ProcessInfo.processInfo.arguments.contains("--event-fixtures") {
            var event = EventDraft(anchor: created[0]); event.title = "Silverstone weekend"; event.location = "Silverstone"
            try event.save(in: context, anchorID: created[0].objectID)
            var booking = JobDraft(); booking.clientName = "Apex Media"; booking.fee?.amount = "600"
            let id = try event.save(in: context, firstBooking: booking)
            let added = try context.existingObject(with: id) as! Job
            var race = SessionDraft(job: added); race.name = "Race coverage"; race.overridesSeries = true; race.seriesName = "Support championship"
            try race.save(in: context, jobID: id)
        }

    }
    static func seedToday(_ context: NSManagedObjectContext) throws {
        let day = Calendar.current.startOfDay(for: Date())
        for (index, name) in ["Silverstone weekend", "Studio highlights"].enumerated() {
            var job = JobDraft(name: name, startDate: day, endDate: day)
            job.clientName = index == 0 ? "Northside Sports" : "Apex Broadcast"
            job.bookingStatus = .booked
            job.timeZoneID = TimeZone.current.identifier
            let id = try job.save(in: context)
            let times: [(String, Double, Double)] = index == 0 ? [("Qualifying", 10.5, 11.5), ("Race briefing", 13.5, 14), ("Feature race", 15, 16.5)] : [("Evening review", 19, 20)]
            for (name, hour, end) in times {
                var row = SessionDraft(day: Day.string(from: day), timeZoneID: TimeZone.current.identifier)
                row.name = name; row.startTime = day.addingTimeInterval(hour * 3600)
                row.endTime = day.addingTimeInterval(end * 3600); row.callTime = row.startTime!.addingTimeInterval(-1800)
                row.scheduleStatus = "confirmed"; row.coverage = "covering"
                try row.save(in: context, jobID: id)
            }
        }
    }

}

struct DesignFixtureScreen: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: true)]) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Invoice.createdAt, ascending: true)]) private var invoices: FetchedResults<Invoice>
    @State private var filter: JobFilter = {
        var filter = JobFilter()
        filter.usesDates = DesignFixtures.route == "filters-dates"
        return filter
    }()
    @State private var editorPresented = true
    var body: some View {
        if ["widgets", "accessories"].contains(DesignFixtures.route) { WidgetFixtureGallery() }
        else if ["root", "pending-root", "expenses-overview"].contains(DesignFixtures.route) { RootView() }
        else if let job = jobs.first, let invoice = invoices.first {
            NavigationStack {
                switch DesignFixtures.route {
                case "expense": JobDetailView(job: job).sheet(isPresented: $editorPresented) {
                    if let expense = job.expenses?.first { ExpenseEditorView(job: job, expense: expense) }
                }
                case "pending-expenses": PendingExpensesView()
                case "expense-automation": ExpenseAutomationSettingsView()
                case "expense-notification": Text("Opening expense…").task {
                    let request = NSFetchRequest<Expense>(entityName: "Expense")
                    if let expense = try? context.fetch(request).first(where: { $0.value.merchant == "Hotel" }), let id = expense.id {
                        ExpenseNotifications.shared.open(userInfo: ["expenseID": id.uuidString])
                    }
                }
                case "receipt-shortcut": ReceiptEventPicker()
                case "recently-deleted": RecentlyDeletedView()
                case "backups": BackupView(cloud: FixtureBackups.shared, preview: true)
                case "event": EventDetailView(anchor: job)
                case "edit-event": EventDetailView(anchor: job).sheet(isPresented: $editorPresented) { EventEditorView(anchor: job) }
                case "job": JobDetailView(job: job)
                case "add-job": JobDetailView(job: job).sheet(isPresented: $editorPresented) { JobEditorView() }
                case "edit-job": JobDetailView(job: job).sheet(isPresented: $editorPresented) { JobEditorView(job: job) }
                case "session": if let session = job.activeSessions.first { SessionDetailView(session: session) }
                case "edit-session": JobDetailView(job: job).sheet(isPresented: $editorPresented) { SessionEditorView(job: job, session: job.activeSessions.first) }
                case "fee": FeeDetailView(job: job)
                case "edit-fee": FeeDetailView(job: job).sheet(isPresented: $editorPresented) { if let draft = try? FeeDraft(job: job) { FeeEditorView(job: job, draft: draft) } }
                case "payments": PaymentsView()
                case "invoice": InvoiceDetailView(invoice: invoice)
                case "edit-invoice": InvoiceDetailView(invoice: invoice).sheet(isPresented: $editorPresented) { if let draft = try? InvoiceDraft(invoice: invoice) { InvoiceEditorView(invoice: invoice, draft: draft) } }
                case "payment": InvoiceDetailView(invoice: invoice).sheet(isPresented: $editorPresented) { PaymentEditorView(invoice: invoice) }
                case "receipt": if let receipt = invoice.payments?.first { ReceiptDetailView(payment: receipt) }
                case "edit-client": LibraryView(kind: .client).sheet(isPresented: $editorPresented) { LibraryEditor(kind: .client, record: job.client) }
                case "edit-project": LibraryView(kind: .project).sheet(isPresented: $editorPresented) { LibraryEditor(kind: .project, record: job.project) }
                case "edit-series": LibraryView(kind: .series).sheet(isPresented: $editorPresented) { LibraryEditor(kind: .series, record: job.series) }
                case "edit-role": LibraryView(kind: .role).sheet(isPresented: $editorPresented) { LibraryEditor(kind: .role, record: job.roles?.first) }
                case "client": if let client = job.client { LibraryDetailView(record: client, kind: .client) }
                case "project": if let project = job.project { LibraryDetailView(record: project, kind: .project) }
                case "series": if let series = job.series { LibraryDetailView(record: series, kind: .series) }
                case "clients": LibraryView(kind: .client)
                case "settings": SettingsView()
                case "calendar": CalendarSettingsView()
                case "filters", "filters-dates": RootView().sheet(isPresented: $editorPresented) { JobFiltersView(filter: $filter) }
                default: RootView()
                }
            }
        } else { ProgressView("Loading review records…") }
    }
}
/// Test-only transport. UI workflows exercise real archive generation and restore
/// without reading or writing the signed-in user's private iCloud database.
actor FixtureBackups: CloudBacking {
    static let shared = FixtureBackups()
    private var values: [String: (CloudBackupStore.Entry, Data)] = [:]
    func list() async throws -> [CloudBackupStore.Entry] { values.values.map { $0.0 }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) } }
    func latestDate() async throws -> Date? { try await list().filter(\.canRestore).compactMap(\.date).max() }
    func save(file: URL, date: Date, events: Int) async throws {
        let data = try Data(contentsOf: file)
        let id = CKRecord.ID(recordName: UUID().uuidString)
        values[id.recordName] = (CloudBackupStore.Entry(id: id, date: date, bytes: Int64(data.count), events: events), data)
    }
    func load(_ entry: CloudBackupStore.Entry) async throws -> URL {
        guard let value = values[entry.id.recordName] else { throw RecordError.invalid("Backup not found.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Fixture-\(UUID()).zip")
        try value.1.write(to: url)
        return url
    }
    func delete(_ entry: CloudBackupStore.Entry) async throws { values[entry.id.recordName] = nil }
}
#endif

#if DEBUG
struct WidgetFixtureGallery: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.colorScheme) private var appearance
    var body: some View {
        ScrollView {
            if let snapshot = try? DaySchedule.capture(in: context) {
                VStack(spacing: 24) {
                    if DesignFixtures.route == "accessories" {
                        Text("Lock Screen accessories").font(.title2.bold())
                        Text("Rectangular").font(.headline)
                        specimen(snapshot, hour: 9, family: .accessoryRectangular, width: 170, height: 80)
                        Text("Circular").font(.headline)
                        specimen(snapshot, hour: 9, family: .accessoryCircular, width: 80, height: 80)
                        Text("Inline").font(.headline)
                        specimen(snapshot, hour: 9, family: .accessoryInline, width: 320, height: 36)
                    } else {
                    Text("Small widget · one event").font(.headline)
                    specimen(snapshot, hour: 9, family: .systemSmall, width: 170, height: 170)
                    Text("Small widget · across events").font(.headline)
                    specimen(snapshot, hour: 14, family: .systemSmall, width: 170, height: 170)
                    Text("Medium widget").font(.headline)
                    specimen(snapshot, hour: 9, family: .systemMedium, width: 360, height: 170)
                    Text("Lock Screen · rectangular").font(.headline)
                    specimen(snapshot, hour: 9, family: .accessoryRectangular, width: 170, height: 80)
                    }
                }.padding()
            }
        }.daybookSurface()
    }
    private func specimen(_ snapshot: DaySchedule, hour: Double, family: WidgetFamily, width: CGFloat, height: CGFloat) -> some View {
        ScheduleWidgetView(familyOverride: family, entry: ScheduleEntry(date: Calendar.current.startOfDay(for: Date()).addingTimeInterval(hour * 3600), schedule: snapshot))
            .padding(family == .systemSmall || family == .systemMedium ? 14 : 4).frame(width: width, height: height)
            .background(Color("PageBackground"), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.secondary.opacity(0.25)))
    }
}
#endif
