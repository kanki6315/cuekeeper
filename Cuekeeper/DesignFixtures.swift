#if DEBUG
import CoreData
import SwiftUI

/// Synthetic review records, gated to the isolated UI-test store. Never used in a normal launch.
enum DesignFixtures {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--design-fixtures") }
    static var route: String { ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--design-screen=") })?.replacingOccurrences(of: "--design-screen=", with: "") ?? "root" }
    static func seed(_ context: NSManagedObjectContext) throws {
        guard enabled, try context.count(for: NSFetchRequest<Job>(entityName: "Job")) == 0 else { return }
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
        session.links = [LinkDraft(label: "Programme feed", url: "https://example.com/live", notes: "Producer’s programme feed")]
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
        if ProcessInfo.processInfo.arguments.contains("--event-fixtures") {
            var event = EventDraft(anchor: created[0]); event.title = "Silverstone weekend"; event.location = "Silverstone"
            try event.save(in: context, anchorID: created[0].objectID)
            var booking = JobDraft(); booking.clientName = "Apex Media"; booking.fee?.amount = "600"
            let id = try booking.saveBooking(in: context, anchorID: created[0].objectID)
            let added = try context.existingObject(with: id) as! Job
            var race = SessionDraft(job: added); race.name = "Race coverage"; race.overridesSeries = true; race.seriesName = "Support championship"
            try race.save(in: context, jobID: id)
        }

    }
}

struct DesignFixtureScreen: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: true)]) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Invoice.createdAt, ascending: true)]) private var invoices: FetchedResults<Invoice>
    @State private var filter = JobFilter()
    @State private var zone = "Europe/London"
    @State private var editorPresented = true
    var body: some View {
        if DesignFixtures.route == "root" { RootView() }
        else if let job = jobs.first, let invoice = invoices.first {
            NavigationStack {
                switch DesignFixtures.route {
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
                case "filters": RootView().sheet(isPresented: $editorPresented) { JobFiltersView(filter: $filter) }
                case "timezone": TimeZonePicker(selection: $zone)
                case "link": JobDetailView(job: job).sheet(isPresented: $editorPresented) { BroadcastLinkEditorView(job: job, session: job.activeSessions.first) }
                default: RootView()
                }
            }
        } else { ProgressView("Loading review records…") }
    }
}
#endif
