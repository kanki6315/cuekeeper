import CoreData
import SwiftUI

/// Compatibility entry point for existing navigation and fixture routes.
struct JobEditorView: View {
    var job: Job? = nil
    var duplicating = false
    var body: some View {
        if let job, !duplicating { EventEditorView(anchor: job) }
        else { EventWizardView(template: duplicating ? job : nil) }
    }
}

struct JobFiltersView: View {
    @Binding var filter: JobFilter
    @State private var contentHeight: CGFloat = 360
    @State private var navigationHeight: CGFloat = 56
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Client.name, ascending: true)]) private var clients: FetchedResults<Client>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkProject.name, ascending: true)]) private var projects: FetchedResults<WorkProject>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkSeries.name, ascending: true)]) private var series: FetchedResults<WorkSeries>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkRole.name, ascending: true)]) private var roles: FetchedResults<WorkRole>
    var body: some View {
        NavigationStack {
            DaybookForm(compact: true, onContentHeightChange: { contentHeight = $0 }) {
                Section {
                    DaybookPicker("Client", selection: $filter.client) {
                        Text("Any client").tag("")
                        ForEach(Array(Set(clients.map(\.name))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    DaybookPicker("Project", selection: $filter.project) {
                        Text("Any project").tag("")
                        ForEach(Array(Set(projects.map(\.name))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    DaybookPicker("Series", selection: $filter.series) {
                        Text("Any series").tag("")
                        ForEach(Array(Set(series.map(\.name))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    DaybookPicker("Role", selection: $filter.role) {
                        Text("Any role").tag("")
                        ForEach(Array(Set(roles.map(\.name))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    Toggle("Limit date range", isOn: $filter.usesDates)
                    if filter.usesDates {
                        DatePicker("From", selection: $filter.start, displayedComponents: .date)
                        DatePicker("Through", selection: $filter.end, in: filter.start..., displayedComponents: .date)
                    }
                }
            }.navigationTitle("Filter Events").navigationBarTitleDisplayMode(.inline)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.safeAreaInsets.top
                } action: { height in
                    navigationHeight = height
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Reset") { filter = JobFilter() }
                            .disabled(!filter.isActive)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .onChange(of: filter.start) { _, start in if filter.end < start { filter.end = start } }
        }
        .presentationDetents([.height(contentHeight + navigationHeight), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color("PageBackground"))
    }
}

/// Shared by both editors so a failed save is visible even when a long form is scrolled.
extension View {
    func saveErrorAlert(_ error: Binding<String?>) -> some View {
        alert("Couldn’t save changes", isPresented: Binding(
            get: { error.wrappedValue != nil },
            set: { if !$0 { error.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) { error.wrappedValue = nil }
        } message: {
            Text(error.wrappedValue ?? "Please try again.")
        }
    }
}
