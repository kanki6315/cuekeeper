import CoreData
import SwiftUI
import UIKit

struct RecentlyDeletedView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.deletedAt, ascending: false)], predicate: NSPredicate(format: "deletedAt != nil AND recoveryDiscardedAt == nil")) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkSession.deletedAt, ascending: false)], predicate: NSPredicate(format: "deletedAt != nil AND recoveryDiscardedAt == nil")) private var sessions: FetchedResults<WorkSession>
    @State private var discarding: NSManagedObject?
    @State private var confirmDiscard = false
    @State private var showRecoveryInfo = false
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let recoverableJobs = jobs.filter { Recovery.canRestore($0, now: timeline.date) }
            let recoverableSessions = sessions.filter { Recovery.canRestore($0, now: timeline.date) && $0.job?.deletedAt == nil }
            DaybookList(sectionSpacing: 8) {
                Section {
                    Text("Restore deleted items for 30 days.")
                        .font(.subheadline)
                        .foregroundStyle(Color.theme.secondaryText)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .environment(\.defaultMinListRowHeight, 0)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
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
            .contentMargins(.top, 0, for: .scrollContent)
        }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.subheadline).padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false).accessibilityIdentifier("recovery-notice")
            }
        }
        .animation(.default, value: notice)
        .task(id: notice) {
            guard let notice else { return }
            UIAccessibility.post(notification: .announcement, argument: notice)
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self.notice = nil
        }
        .navigationTitle("Recently Deleted").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("About recovery", systemImage: "info.circle") { showRecoveryInfo = true }
            }
        }
        .alert("About recovery", isPresented: $showRecoveryInfo) {
            Button("Done", role: .cancel) { }
        } message: {
            Text("Swipe right to restore or left to delete, then tap the action.\n\nRestoring an event brings back its schedule and eligible calendar entries. Restore separately deleted sessions individually.\n\nInvoices and payments are always kept.")
        }
        .saveErrorAlert($error)
        .alert("Permanently remove from Recently Deleted?", isPresented: $confirmDiscard) {
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
            Text(subtitle).font(.subheadline).foregroundStyle(Color.theme.secondaryText)
            if let deadline = Recovery.deadline(record) {
                Text("Restore by \(deadline.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(Color.theme.secondaryText)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button("Restore", systemImage: "arrow.uturn.backward") { restore(record, title: title) }
                .tint(Color.theme.accent)
                .accessibilityLabel("Restore \(title)")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Only mark the confirmation button destructive: revealing this action
            // must not optimistically remove the row before the user confirms.
            Button("Delete", systemImage: "trash") { requestDiscard(record) }
                .tint(Color.theme.destructive)
                .accessibilityLabel("Permanently delete \(title)")
        }
        .contextMenu {
            Button("Restore", systemImage: "arrow.uturn.backward") { restore(record, title: title) }
            Button("Delete Permanently", systemImage: "trash", role: .destructive) { requestDiscard(record) }
        }
        .accessibilityAction(named: "Restore") { restore(record, title: title) }
        .accessibilityAction(named: "Delete Permanently") { requestDiscard(record) }
    }

    private func restore(_ record: NSManagedObject, title: String) {
        do { try Recovery.restore(record.objectID, in: context); notice = "Restored \(title)." }
        catch { self.error = error.localizedDescription }
    }

    private func requestDiscard(_ record: NSManagedObject) {
        discarding = record
        confirmDiscard = true
    }
}
