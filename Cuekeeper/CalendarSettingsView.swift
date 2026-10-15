import SwiftUI

struct CalendarSettingsView: View {
    @EnvironmentObject private var calendar: CalendarController
    @State private var selected = ""
    @State private var disconnect = false
    @State private var takeOver = false
    var body: some View {
        DaybookForm {
            Section {
                LabeledContent("Permission", value: calendar.permission)
                Text(calendar.status).accessibilityIdentifier("calendar-status")
                if calendar.busy { ProgressView("Updating Calendar…") }
            } header: { Text("Connection") } footer: {
                Text("One device updates Calendar to avoid duplicates. To include edits from other devices, open Cuekeeper here while online. Your events are still available offline.")
            }
            if calendar.calendars.isEmpty {
                Section {
                    Button("Allow Calendar Access") { Task { await calendar.requestAccess() } }
                    Link("Open System Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    Text("Allow full access to add and update entries. If access is already allowed, add an editable calendar in Calendar.").foregroundStyle(Color("SecondaryText"))
                }
            } else {
                Section("Calendar") {
                    Menu {
                        Picker("Calendar", selection: $selected) {
                            Text("Choose a calendar").tag("")
                            ForEach(calendar.calendars, id: \.calendarIdentifier) {
                                Text("\($0.title) · \($0.source.title)").tag($0.calendarIdentifier)
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedCalendarTitle)
                                if let choice = calendar.calendars.first(where: { $0.calendarIdentifier == selected }) {
                                    Text(choice.source.title)
                                        .font(.subheadline)
                                        .foregroundStyle(Color("SecondaryText"))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .accessibilityHidden(true)
                        }
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Calendar")
                    .accessibilityValue(selectedCalendarDescription)
                    Button(calendar.connected ? "Use This Calendar" : "Connect This Device") { Task { await calendar.connect(selected) } }
                        .disabled(selected.isEmpty || calendar.busy)
                }
                if let owner = calendar.otherOwner {
                    Section {
                        Button("Use This Device Instead") { takeOver = true }
                            .disabled(selected.isEmpty || calendar.busy)
                    } footer: {
                        Text("Managed by \(owner). If that device was replaced, reset, or reinstalled, this device can take over. Existing Cuekeeper entries are kept and updated here.")
                    }
                }
            }
            if calendar.connected {
                Section {
                    Button("Update Now") { Task { await calendar.sync() } }.disabled(calendar.busy)
                    Button("Disconnect & Remove Entries", role: .destructive) { disconnect = true }.disabled(calendar.busy)
                } footer: { Text("Only entries added by Cuekeeper are updated or removed. Changes in Calendar won’t sync back to Cuekeeper.") }
            }
        }
        .navigationTitle("Calendar").navigationBarTitleDisplayMode(.inline)
        .task { calendar.refreshCalendars(); selected = calendar.selectedID }
        .confirmationDialog("Remove Cuekeeper’s entries from this calendar and disconnect?", isPresented: $disconnect, titleVisibility: .visible) {
            Button("Disconnect & Remove Entries", role: .destructive) { Task { await calendar.disconnect() } }
        }
        .confirmationDialog("Make this device the calendar manager?", isPresented: $takeOver, titleVisibility: .visible) {
            Button("Use This Device") { Task { await calendar.takeOver(selected) } }
        } message: {
            Text("The other device will stop updating Calendar. Choose the same calendar it used to keep entries from being duplicated.")
        }
    }

    private var selectedCalendarTitle: String {
        calendar.calendars.first(where: { $0.calendarIdentifier == selected })?.title
            ?? (selected.isEmpty ? "Choose a calendar" : "Calendar unavailable")
    }

    private var selectedCalendarDescription: String {
        guard let choice = calendar.calendars.first(where: { $0.calendarIdentifier == selected }) else {
            return selectedCalendarTitle
        }
        return "\(choice.title), \(choice.source.title)"
    }
}
