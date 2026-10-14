import CoreData
import SwiftUI
import UIKit

/// Reuses the existing edit routes. There is deliberately no EventWizardView here:
/// every editor is anchored to the job that Siri already saved.
struct SiriCreatedEventView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    let request: EventEditorHandoff.Request
    @State private var noticeVisible = true

    var body: some View {
        NavigationStack {
            Group {
                if let job = try? context.existingObject(with: request.jobID) as? Job, !job.isDeleted {
                    EventDetailView(anchor: job)
                } else {
                    ContentUnavailableView("Event unavailable", systemImage: "calendar", description: Text("This event could not be opened. Check your event list."))
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }.accessibilityIdentifier("siri-event-done")
            } }
        }
        .overlay(alignment: .top) {
            if noticeVisible && !request.notices.isEmpty {
                Label(request.notices.joined(separator: "\n"), systemImage: "exclamationmark.circle")
                    .font(.subheadline).padding().foregroundStyle(.primary)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: 520).padding().padding(.top, 56)
                    .allowsHitTesting(false).accessibilityIdentifier("siri-import-notice")
            }
        }
        .task {
            guard !request.notices.isEmpty else { return }
            UIAccessibility.post(notification: .announcement, argument: request.notices.joined(separator: "\n"))
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            withAnimation { noticeVisible = false }
        }
    }
}
