import CoreData
import SwiftUI

struct RecentlyDeletedView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.deletedAt, ascending: false)], predicate: NSPredicate(format: "deletedAt != nil AND recoveryDiscardedAt == nil")) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkSession.deletedAt, ascending: false)], predicate: NSPredicate(format: "deletedAt != nil AND recoveryDiscardedAt == nil")) private var sessions: FetchedResults<WorkSession>
    @State private var discarding: NSManagedObject?
    @State private var confirmDiscard = false
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let recoverableJobs = jobs.filter { Recovery.canRestore($0, now: timeline.date) }
            let recoverableSessions = sessions.filter { Recovery.canRestore($0, now: timeline.date) && $0.job?.deletedAt == nil }
            DaybookForm(title: "Recently Deleted") {
                Section {
                    Text("Restore events and sessions for 30 days after deletion. Restoring an event brings back its schedule and eligible calendar entries. Sessions deleted separately stay here until you restore them.")
                    Text("Invoices and payments are preserved, even after recovery ends.").foregroundStyle(Color("SecondaryText"))
                }
                if let notice { Section { Text(notice).accessibilityIdentifier("recovery-notice") } }
                if recoverableJobs.isEmpty && recoverableSessions.isEmpty {
                    Section { ContentUnavailableView("Nothing to recover", systemImage: "trash", description: Text("Events and sessions deleted within the last 30 days appear here.")) }
                }
                if !recoverableJobs.isEmpty {
                    Section("Events") {
                        ForEach(recoverableJobs, id: \.objectID) { job in
                            recoveryRow(job, title: job.eventTitle, subtitle: job.client?.name ?? "Client to add")
                        }
                    }
                }
                if !recoverableSessions.isEmpty {
                    Section("Sessions") {
                        ForEach(recoverableSessions, id: \.objectID) { session in
                            recoveryRow(session, title: session.title, subtitle: session.job?.eventTitle ?? "Event")
                        }
                    }
                }
            }
        }
        .navigationTitle("Recently Deleted").navigationBarTitleDisplayMode(.inline)
        .saveErrorAlert($error)
        .confirmationDialog("Permanently remove from Recently Deleted?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                guard let record = discarding else { return }
                do { try Recovery.discard(record.objectID, in: context); notice = "Removed from Recently Deleted." }
                catch { self.error = error.localizedDescription }
                discarding = nil
            }
            Button("Cancel", role: .cancel) { discarding = nil }
        } message: {
            Text("You won’t be able to restore this record here. Financial history is kept. Copies in existing backups are not removed.")
        }
    }

    private func recoveryRow(_ record: NSManagedObject, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(Color("SecondaryText"))
            if let deadline = Recovery.deadline(record) {
                Text("Recover before \(deadline.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(Color("SecondaryText"))
            }
            ViewThatFits(in: .horizontal) {
                HStack { actions(record, title: title) }
                VStack(alignment: .leading) { actions(record, title: title) }
            }
        }
    }

    @ViewBuilder private func actions(_ record: NSManagedObject, title: String) -> some View {
        Button("Restore", systemImage: "arrow.uturn.backward") {
            do { try Recovery.restore(record.objectID, in: context); notice = "Restored \(title)." }
            catch { self.error = error.localizedDescription }
        }.frame(minHeight: 44).accessibilityLabel("Restore \(title)")
        Button("Delete Permanently", role: .destructive) { discarding = record; confirmDiscard = true }
            .frame(minHeight: 44).accessibilityLabel("Permanently delete \(title)")
    }
}
