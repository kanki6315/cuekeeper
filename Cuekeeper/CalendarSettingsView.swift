import SwiftUI

struct CalendarSettingsView: View {
    @EnvironmentObject private var calendar: CalendarController
    @State private var selected = ""
    @State private var disconnect = false
    var body: some View {
        Form {
            Section {
                LabeledContent("Permission", value: calendar.permission)
                Text(calendar.status).accessibilityIdentifier("calendar-status")
                if calendar.busy { ProgressView("Updating Calendar…") }
            } header: { Text("Connection") } footer: {
                Text("One device manages calendar entries to prevent duplicates. Edits from your other devices reach Calendar when this device opens Cuekeeper with an internet connection. Your jobs remain usable offline.")
            }
            if calendar.calendars.isEmpty {
                Section {
                    Button("Allow Calendar Access") { Task { await calendar.requestAccess() } }
                    Link("Open System Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    Text("Choose full access so Cuekeeper can update its existing entries. If access is already allowed, add a writable calendar in Calendar first.").foregroundStyle(.secondary)
                }
            } else {
                Section("Destination") {
                    Picker("Calendar", selection: $selected) {
                        Text("Choose calendar").tag("")
                        ForEach(calendar.calendars, id: \.calendarIdentifier) { Text("\($0.title) · \($0.source.title)").tag($0.calendarIdentifier) }
                    }
                    Button(calendar.connected ? "Use Selected Calendar" : "Connect This Device") { Task { await calendar.connect(selected) } }
                        .disabled(selected.isEmpty || calendar.busy)
                }
            }
            if calendar.connected {
                Section {
                    Button("Update Calendar Now") { Task { await calendar.sync() } }.disabled(calendar.busy)
                    Button("Disconnect & Remove Entries", role: .destructive) { disconnect = true }.disabled(calendar.busy)
                } footer: { Text("Only Cuekeeper-marked entries in the selected calendar are managed. Editing Calendar events does not change your jobs in Cuekeeper.") }
            }
        }
        .navigationTitle("Calendar").navigationBarTitleDisplayMode(.inline)
        .task { calendar.refreshCalendars(); selected = calendar.selectedID }
        .confirmationDialog("Remove Cuekeeper’s entries from this calendar and disconnect?", isPresented: $disconnect, titleVisibility: .visible) {
            Button("Disconnect & Remove Entries", role: .destructive) { Task { await calendar.disconnect() } }
        }
    }
}
