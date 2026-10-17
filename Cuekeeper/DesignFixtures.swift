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
        // Minimal prerequisite for workflow tests: no sessions, invoices or agreed fee.
        // `enabled` above confines this to the isolated UI-test store in Debug builds.
        let arguments = ProcessInfo.processInfo.arguments
        if let title = arguments.first(where: { $0.hasPrefix("--workflow-event-title=") }) {
            let day = Calendar.current.startOfDay(for: Date())
            var draft = JobDraft(name: String(title.dropFirst("--workflow-event-title=".count)), startDate: day, endDate: day)
            draft.clientName = arguments.first(where: { $0.hasPrefix("--workflow-event-client=") })
                .map { String($0.dropFirst("--workflow-event-client=".count)) } ?? "Studio Network"
            draft.timeZoneID = TimeZone.current.identifier
            _ = try draft.save(in: context)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--today-fixtures") {
            try seedToday(context)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--payments-fixtures") {
            try seedPayments(context)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--identity-conflict-fixtures") {
            try seedIdentityConflicts(context)
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
            // The Roles screen needs events held in more than one role.
            draft.roleNames = ["roles", "role"].contains(route)
                ? [["Commentator"], ["Presenter"], ["Commentator", "Pit reporter"], ["Commentator"], ["Pit reporter"], ["Commentator"]][index]
                : ["Commentator"]
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
        if ProcessInfo.processInfo.arguments.contains("--upcoming-past-fixture") {
            // A booked event that has ended, so Upcoming asks to mark it completed.
            let day = start.addingTimeInterval(-2 * 86400)
            var past = JobDraft(name: "Cup replay", startDate: day, endDate: day)
            past.clientName = "Northside Sports"; past.roleNames = ["Commentator"]; past.bookingStatus = .booked
            past.timeZoneID = TimeZone.current.identifier
            past.fee?.amount = "300"; past.fee?.agreement = "agreed"
            _ = try past.save(in: context)
        }
        if ["expense", "pending-expenses", "expense-notification", "pending-root", "expenses-overview", "expenses-inbox"].contains(route) {
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
        if route == "expenses-overview" || route == "expenses-inbox" {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { renderer in
                UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
                ("SYNTHETIC RECEIPT" as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.foregroundColor: UIColor.black])
            }
            for (index, merchant) in ["Trackside Cafe", "Rail Europe"].enumerated() {
                let id = try Expense.capture(image.jpegData(compressionQuality: 0.9)!, jobID: created[index].objectID, in: context)
                let expense = try context.existingObject(with: id) as! Expense
                try Expense.save(ExpenseValue(merchant: merchant, day: "2026-10-14", amount: index == 0 ? "18.50" : "86.00", currency: index == 0 ? "USD" : "EUR", category: index == 0 ? "Meals" : "Travel", reimbursable: index == 1), id: id, revision: expense.revision, in: context)
            }
            // Business costs with no event; Claude Pro's next month is due.
            for (merchant, day, amount, currency, repeats) in [("Claude Pro", "2026-09-01", "20.00", "USD", true), ("Adobe Creative Cloud", "2026-10-04", "59.99", "USD", true),
                                                               ("Dropbox Plus", "2026-10-09", "11.99", "EUR", false)] {
                var value = ExpenseValue(merchant: merchant, day: day, amount: amount, currency: currency, category: "Software")
                value.repeatsMonthly = repeats
                _ = try Expense.createBusiness(value, in: context)
            }
            if route == "expenses-inbox" {
                // A receipt holding up an event's invoice, and months of unassigned Wallet captures.
                _ = try Expense.capture(image.jpegData(compressionQuality: 0.9)!, jobID: created[2].objectID, in: context)
                for (index, (merchant, amount)) in [("Harris Teeter #0218", "42.17"), ("Starbucks", "6.85"), ("Target", "31.40"), ("CVS Pharmacy", "12.09"),
                                                    ("Trader Joe’s", "54.22"), ("Chipotle", "14.75"), ("Shell", "61.02")].enumerated() {
                    _ = try Expense.captureBackground(ExpenseCaptureInput(merchant: merchant, amount: amount, currency: "USD",
                                                                          date: Date().addingTimeInterval(-Double(40 + index * 9) * 86400),
                                                                          transactionID: "fixture-stale-\(index)"), in: context)
                }
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
    /// One event and one payment that each exist as two differing copies of one UUID,
    /// as after a backup restored before iCloud finished delivering, for record review.
    static func seedIdentityConflicts(_ context: NSManagedObjectContext) throws {
        let day = Calendar.current.startOfDay(for: Date())
        var draft = JobDraft(name: "Silverstone 6 Hours", startDate: day, endDate: day.addingTimeInterval(86400))
        draft.clientName = "Velocity TV"; draft.fee?.amount = "1000"; draft.timeZoneID = "Europe/London"
        let job = try XCTUnwrapFixture(context.existingObject(with: try draft.save(in: context)) as? Job)
        job.notes = "Pit lane reporter, arrive 07:00"; job.bookingStatus = "booked"; try context.save()
        var session = SessionDraft(day: job.startDay, timeZoneID: "Europe/London")
        session.startTime = day.addingTimeInterval(9 * 3600); session.endTime = day.addingTimeInterval(15 * 3600)
        try session.save(in: context, jobID: job.objectID)
        var invoice = InvoiceDraft(clientID: job.client!.id!, currency: "USD")
        invoice.value.reference = "INV-0142"; invoice.value.status = "sent"; invoice.value.sentDay = Day.string(from: day)
        invoice.value.lines = [BilledLine(jobID: job.id!, jobName: job.displayName, amount: 100000)]
        let invoiceID = try invoice.save(in: context)
        var payment = PaymentDraft(amount: "250"); payment.note = "Bank transfer"
        try payment.save(in: context, invoiceID: invoiceID)
        func copy(_ object: NSManagedObject) -> NSManagedObject {
            let copy = NSEntityDescription.insertNewObject(forEntityName: object.entity.name!, into: context)
            for name in object.entity.attributesByName.keys { copy.setValue(object.value(forKey: name), forKey: name) }
            for (name, relationship) in object.entity.relationshipsByName where !relationship.isToMany {
                copy.setValue(object.value(forKey: name), forKey: name)
            }
            return copy
        }
        let other = copy(job)
        other.setValue("Silverstone 6H", forKey: "name"); other.setValue("tentative", forKey: "bookingStatus"); other.setValue("", forKey: "notes")
        let receipt = try XCTUnwrapFixture(context.fetch(NSFetchRequest<PaymentRecord>(entityName: "PaymentRecord")).first)
        copy(receipt).setValue(Int64(20500), forKey: "amount")
        try context.save()
    }
    private static func XCTUnwrapFixture<T>(_ value: T?) throws -> T {
        guard let value else { throw RecordError.invalid("Fixture record missing.") }
        return value
    }
    /// A month in progress: ready, held-up, upcoming, invoiced and paid work across four clients,
    /// plus invoices still open from the previous month. Dates are relative to today.
    static func seedPayments(_ context: NSManagedObjectContext) throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
        let day = { (offset: Int) in calendar.date(byAdding: .day, value: offset, to: month)! }
        let ahead = { (offset: Int) in calendar.date(byAdding: .day, value: offset, to: today)! }
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 260)).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 200, height: 260))
            ("SYNTHETIC RECEIPT" as NSString).draw(at: CGPoint(x: 16, y: 20), withAttributes: [.foregroundColor: UIColor.black])
        }.jpegData(compressionQuality: 0.8)!
        var jobs: [String: Job] = [:]
        func event(_ name: String, client: String, start: Date, end: Date? = nil, status: BookingStatus, fee: String?, currency: String) throws {
            var draft = JobDraft(name: name, startDate: start, endDate: end ?? start)
            draft.clientName = client; draft.bookingStatus = status; draft.roleNames = ["Commentator"]
            draft.timeZoneID = TimeZone.current.identifier
            draft.fee?.currency = currency; draft.fee?.amount = fee ?? ""; draft.fee?.agreement = fee == nil ? "unknown" : "agreed"
            jobs[name] = try context.existingObject(with: try draft.save(in: context)) as? Job
        }
        func receipt(_ name: String, merchant: String, amount: String, reimbursable: Bool, finished: Bool) throws {
            let id = try Expense.capture(photo, jobID: jobs[name]!.objectID, in: context)
            let expense = try context.existingObject(with: id) as! Expense
            try Expense.save(ExpenseValue(merchant: merchant, day: jobs[name]!.startDay, amount: amount, currency: "EUR", category: "Travel", reimbursable: reimbursable),
                             id: id, revision: expense.revision, confirmed: finished, in: context)
        }
        func invoice(_ reference: String, client: String, currency: String, events: [(String, Int64)], status: String = "sent", sent: Date? = nil, due: Date? = nil) throws -> NSManagedObjectID {
            var draft = InvoiceDraft(clientID: jobs[events[0].0]!.client!.id!, currency: currency)
            draft.value.reference = reference; draft.value.status = status
            draft.value.lines = events.map { BilledLine(jobID: jobs[$0.0]!.id!, jobName: $0.0, amount: $0.1) }
            if let sent { draft.value.sentDay = Day.string(from: sent) }
            if let due { draft.value.dueDay = Day.string(from: due) }
            return try draft.save(in: context)
        }
        // Earlier month, still open.
        let previous = calendar.date(byAdding: .month, value: -1, to: month)!
        let earlier = { (offset: Int) in calendar.date(byAdding: .day, value: offset, to: previous)! }
        try event("Monza Grand Prix", client: "Apex Media", start: earlier(11), status: .completed, fee: "3150", currency: "USD")
        try event("Late summer special", client: "Trackside Radio", start: earlier(20), status: .completed, fee: "480", currency: "EUR")
        try event("Cup third round", client: "Northside Sports", start: earlier(14), status: .completed, fee: "1300", currency: "EUR")
        try event("League derby", client: "Northside Sports", start: earlier(21), status: .completed, fee: "1300", currency: "EUR")
        _ = try invoice("APX-2207", client: "Apex Media", currency: "USD", events: [("Monza Grand Prix", 315_000)], sent: ahead(-32), due: ahead(-2))
        _ = try invoice("INV-0410", client: "Trackside Radio", currency: "EUR", events: [("Late summer special", 48_000)], sent: ahead(-14), due: today)
        let split = try invoice("INV-0409", client: "Northside Sports", currency: "EUR", events: [("Cup third round", 130_000), ("League derby", 130_000)], sent: ahead(-16), due: ahead(14))
        var part = PaymentDraft(); part.amount = "1300"; part.note = "Part payment"
        try part.save(in: context, invoiceID: split)
        // This month.
        try event("Season launch show", client: "Trackside Radio", start: day(0), status: .completed, fee: "390", currency: "EUR")
        try event("Cup quarter-final", client: "Northside Sports", start: day(2), status: .completed, fee: "650", currency: "EUR")
        try event("Autumn Classic", client: "Trackside Radio", start: day(3), status: .completed, fee: "420", currency: "EUR")
        try event("Podcast guest spot", client: "Velocity TV", start: day(5), status: .completed, fee: "250", currency: "USD")
        try event("Monza preview", client: "Apex Media", start: day(7), status: .completed, fee: "1100", currency: "USD")
        try event("Charity gala", client: "Riverside Trust", start: day(9), status: .completed, fee: "0", currency: "EUR")
        try event("Harbour regatta", client: "Velocity TV", start: day(10), status: .completed, fee: "900", currency: "USD")
        try event("City vs United", client: "Northside Sports", start: day(12), status: .completed, fee: "650", currency: "EUR")
        try event("Silverstone weekend", client: "Northside Sports", start: today, end: ahead(2), status: .booked, fee: "1800", currency: "EUR")
        try event("Studio highlights", client: "Northside Sports", start: ahead(4), status: .tentative, fee: nil, currency: "EUR")
        try event("Brands Hatch finale", client: "Apex Media", start: ahead(8), end: ahead(9), status: .booked, fee: "2400", currency: "USD")
        try event("National finals", client: "Apex Media", start: ahead(14), status: .booked, fee: nil, currency: "USD")
        let paid = try invoice("INV-0401", client: "Trackside Radio", currency: "EUR", events: [("Season launch show", 39_000)], sent: day(1), due: day(15))
        var full = PaymentDraft(); full.amount = "390"; try full.save(in: context, invoiceID: paid)
        _ = try invoice("Draft", client: "Apex Media", currency: "USD", events: [("Monza preview", 110_000)], status: "draft")
        var direct = PaymentDraft(); direct.amount = "250"; direct.note = "Paid on the day"
        try direct.save(in: context, jobID: jobs["Podcast guest spot"]!.objectID)
        try receipt("Cup quarter-final", merchant: "Etihad parking", amount: "25.80", reimbursable: true, finished: true)
        try receipt("Silverstone weekend", merchant: "Fuel, Towcester", amount: "38.40", reimbursable: true, finished: false)
        try receipt("Silverstone weekend", merchant: "Paddock cafe", amount: "14.20", reimbursable: false, finished: false)
        // Client invoicing details: two complete, two with gaps.
        func details(_ client: String, _ value: ClientInvoicing) throws {
            let request = NSFetchRequest<Client>(entityName: "Client"); request.predicate = NSPredicate(format: "name == %@", client)
            try Client.saveInvoicing(value, client: try context.fetch(request).first!.objectID, in: context)
        }
        try details("Northside Sports", ClientInvoicing(billingName: "Northside Sports Media Ltd", email: "accounts@northside.example", address: "14 Wharf Road\nManchester", termsDays: 30))
        try details("Trackside Radio", ClientInvoicing(billingName: "Trackside Radio Ltd", email: "finance@trackside.example", address: "2 Station Lane\nLeeds", termsDays: 14))
        try details("Apex Media", ClientInvoicing(billingName: "Apex Media Inc.", address: "500 Market Street\nSan Francisco", termsDays: 30))
        try details("Velocity TV", ClientInvoicing(billingName: "Velocity Television LLC"))
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
    @State private var expensesMode = ExpensesMode.inbox
    var body: some View {
        if ["widgets", "accessories"].contains(DesignFixtures.route) { WidgetFixtureGallery() }
        else if ["root", "pending-root", "expenses-overview", "expenses-inbox", "payments-root"].contains(DesignFixtures.route) { RootView() }
        else if let job = jobs.first, let invoice = invoices.first {
            NavigationStack {
                switch DesignFixtures.route {
                case "expense": JobDetailView(job: job).sheet(isPresented: $editorPresented) {
                    if let expense = job.expenses?.first { ExpenseEditorView(job: job, expense: expense) }
                }
                case "pending-expenses": ExpensesView(mode: $expensesMode)
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
                case "identity-review": IdentityReviewView()
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
                case "roles", "role": LibraryView(kind: .role)
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
        ScheduleWidgetView(familyOverride: family, entry: ScheduleEntry(date: Calendar.current.startOfDay(for: Date()).addingTimeInterval(hour * 3600), schedule: snapshot, theme: ThemeStore.shared.theme))
            .padding(family == .systemSmall || family == .systemMedium ? 14 : 4).frame(width: width, height: height)
            .background(Color.theme.page, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.secondary.opacity(0.25)))
    }
}
#endif
