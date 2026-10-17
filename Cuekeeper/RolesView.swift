import CoreData
import SwiftUI

/// Settings → Roles: one agenda of the work held in each role, narrowed by a row of role chips.
struct RolesView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkRole.name, ascending: true)]) private var roles: FetchedResults<WorkRole>
    @FetchRequest(sortDescriptors: []) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: []) private var events: FetchedResults<WorkEvent>
    @FetchRequest(sortDescriptors: []) private var sessions: FetchedResults<WorkSession>
    @FetchRequest(sortDescriptors: []) private var invoiceRevisions: FetchedResults<InvoiceRevision>
    @FetchRequest(sortDescriptors: []) private var feeRevisions: FetchedResults<FeeRevision>
    @FetchRequest(sortDescriptors: []) private var payments: FetchedResults<PaymentRecord>
    @SceneStorage("rolesSelection") private var selection = ""
    @State private var query = ""
    @State private var adding = false
    @State private var renaming: RoleFact?
    @State private var merging: Merge?
    @State private var deleting: Removal?
    @State private var expandedYears: Set<String> = []
    @State private var error: String?

    private struct Merge: Identifiable {
        let source: RoleFact
        let target: RoleFact
        let count: Int
        var id: String { source.key + "→" + target.key }
    }

    private struct Removal: Identifiable {
        let role: RoleFact
        let count: Int
        var id: String { role.key }
    }

    var body: some View {
        let _ = (events.count, sessions.count, invoiceRevisions.count, feeRevisions.count, payments.count)
        Group {
            if roles.isEmpty {
                ContentUnavailableView("No roles yet", systemImage: "person.text.rectangle",
                    description: Text("Add one here or while editing a booking."))
                    .daybookSurface()
            } else {
                page(RolesAgenda(roles: Array(roles), jobs: Array(jobs), selected: selection, query: query, context: context))
            }
        }
        .navigationTitle("Roles").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Add Role", systemImage: "plus") { adding = true }.accessibilityIdentifier("add-role") }
        .sheet(isPresented: $adding) { LibraryEditor(kind: .role) }
        .sheet(item: $renaming) { LibraryEditor(kind: .role, record: record($0)) }
        .confirmationDialog(merging.map { "Merge “\($0.source.name)” into “\($0.target.name)”?" } ?? "",
                            isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } }),
                            titleVisibility: .visible, presenting: merging) { merge in
            Button("Merge", role: .destructive) { perform(merge) }
            Button("Cancel", role: .cancel) {}
        } message: { merge in
            Text(merge.count == 0
                 ? "“\(merge.source.name)” will be removed."
                 : "Its \(counted(merge.count, "event", "events")) will show “\(merge.target.name)” instead, and “\(merge.source.name)” will be removed.")
        }
        .confirmationDialog(deleting.map { "Delete “\($0.role.name)”?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { removal in
            Button("Delete Role", role: .destructive) { perform(removal) }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(removal.count == 0
                 ? "It isn't used on any event."
                 : "It's used on \(counted(removal.count, "event", "events")). They keep everything else; only this role is removed from them.")
        }
        .saveErrorAlert($error)
        .onChange(of: selection) { expandedYears = [] }
        .task {
            // Design captures open on a selected role.
            if DesignFixtures.enabled && DesignFixtures.route == "role", selection.isEmpty, let role = roles.first(where: { $0.name == "Commentator" }) {
                selection = RoleFact(role: role).key
            }
        }
    }

    private func page(_ agenda: RolesAgenda) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: typeSize.isAccessibilitySize ? [] : [.sectionHeaders]) {
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        if let focus = agenda.focus { focusPanel(focus, agenda: agenda) }
                        agendaList(agenda)
                    }
                    .padding(.top, 12)
                } header: {
                    chips(agenda).background(Color.theme.page)
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("roles-page")
        .searchable(text: $query, prompt: "Search events")
        .daybookSurface()
    }

    // MARK: Chips

    private func chips(_ agenda: RolesAgenda) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(agenda.chips) { chip in
                        let selected = chip.id == agenda.selectedKey
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { selection = chip.id }
                        } label: {
                            RoleChip(title: chip.role?.name ?? "All", count: chip.count, selected: selected)
                        }
                        .buttonStyle(.plain)
                        .id(chip.id)
                        .accessibilityLabel(chip.role?.name ?? "All roles")
                        .accessibilityValue(counted(chip.count, "event", "events"))
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                        .accessibilityIdentifier("role-chip-\(chip.role?.name ?? "All")")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .onAppear { proxy.scrollTo(agenda.selectedKey, anchor: .center) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Roles")
    }

    // MARK: Selected role

    private func focusPanel(_ focus: RolesAgenda.Focus, agenda: RolesAgenda) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(focus.role.name).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text(Self.focusSubtitle(focus)).font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actions(focus, agenda: agenda)
            }
            if focus.eventCount > 0 {
                RoleYearStrip(focus: focus, today: agenda.today)
                if !focus.clients.isEmpty {
                    ChipFlow(spacing: 6) {
                        ForEach(focus.clients, id: \.name) { client in
                            EventChip {
                                Text(client.name)
                                Text(client.count, format: .number).monospacedDigit().foregroundStyle(Color.theme.secondaryText)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(client.name), \(counted(client.count, "event", "events"))")
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(contrast == .increased ? 0.45 : 0.16), lineWidth: 0.5) }
    }

    static func focusSubtitle(_ focus: RolesAgenda.Focus) -> String {
        guard focus.eventCount > 0 else { return "Not used on any event yet" }
        var parts: [String] = []
        if let since = focus.sinceDay.flatMap({ Day.date(from: $0) }) { parts.append("Since " + since.formatted(.dateTime.month(.abbreviated).year())) }
        parts.append(counted(focus.eventCount, "event", "events"))
        if focus.yearCount > 0 && focus.yearCount < focus.eventCount { parts.append("\(focus.yearCount) in \(focus.year)") }
        return parts.joined(separator: " · ")
    }

    private func actions(_ focus: RolesAgenda.Focus, agenda: RolesAgenda) -> some View {
        let others = agenda.chips.compactMap(\.role).filter { $0.key != focus.role.key }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Menu {
            Button("Rename", systemImage: "pencil") { renaming = focus.role }
            if !others.isEmpty {
                Menu("Merge Into", systemImage: "arrow.triangle.merge") {
                    ForEach(others) { other in
                        Button(other.name) { merging = Merge(source: focus.role, target: other, count: focus.eventCount) }
                    }
                }
            }
            Button("Delete Role", systemImage: "trash", role: .destructive) { deleting = Removal(role: focus.role, count: focus.eventCount) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(Color.theme.accent.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("\(focus.role.name) actions")
        .accessibilityIdentifier("role-actions")
    }

    // MARK: Agenda

    @ViewBuilder private func agendaList(_ agenda: RolesAgenda) -> some View {
        if agenda.isEmpty {
            Text(emptyText(agenda))
                .foregroundStyle(Color.theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            DaybookSections {
                if !agenda.upcoming.isEmpty {
                    Section("Coming up") {
                        ForEach(agenda.upcoming) { row in eventLink(row, agenda: agenda) }
                    }
                }
                ForEach(Array(agenda.past.enumerated()), id: \.element.id) { offset, year in
                    let open = offset == 0 || !query.isEmpty || expandedYears.contains(year.year)
                    Section {
                        if open {
                            ForEach(year.rows) { row in eventLink(row, agenda: agenda) }
                        } else {
                            Button { expandedYears.insert(year.year) } label: {
                                HStack {
                                    Text("Show \(counted(year.rows.count, "event", "events"))")
                                    Spacer()
                                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                                }.frame(minHeight: 32).contentShape(Rectangle())
                            }.foregroundStyle(Color.theme.accent).accessibilityIdentifier("role-year-\(year.year)")
                        }
                    } header: {
                        Text(year.year.isEmpty ? "Dates to come" : year.year)
                    }
                }
            }
        }
        if agenda.focus == nil && agenda.untagged > 0 && query.isEmpty {
            Text("\(counted(agenda.untagged, "event", "events")) without a role \(agenda.untagged == 1 ? "is" : "are") listed on the Events tab only.")
                .font(.footnote).foregroundStyle(Color.theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func emptyText(_ agenda: RolesAgenda) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return "No events match “\(trimmed)”." }
        if let focus = agenda.focus { return "Choose \(focus.role.name) on an event or session and it will appear here." }
        return "No events have a role yet. Choose roles when you add or edit an event."
    }

    @ViewBuilder private func eventLink(_ row: RolesAgenda.Row, agenda: RolesAgenda) -> some View {
        let tags = agenda.focus == nil ? row.roles : []
        let also = agenda.focus == nil ? [] : row.roles
        if let id = row.row.facts.objectID, let job = try? context.existingObject(with: id) as? Job {
            DaybookLink { JobDetailView(job: job) } label: { ClientEventRow(row: row.row, tags: tags, also: also, showsClient: true) }
        } else {
            ClientEventRow(row: row.row, tags: tags, also: also, showsClient: true)
        }
    }

    // MARK: Changes

    private func record(_ fact: RoleFact) -> WorkRole? { roles.first { $0.objectID == fact.objectID } }

    private func perform(_ merge: Merge) {
        guard let source = merge.source.objectID, let target = merge.target.objectID else { return }
        do {
            try WorkRole.merge(source, into: target, in: context)
            selection = merge.target.key
        } catch { self.error = error.localizedDescription }
    }

    private func perform(_ removal: Removal) {
        guard let id = removal.role.objectID else { return }
        do {
            try WorkRole.remove(id, in: context)
            selection = ""
        } catch { self.error = error.localizedDescription }
    }
}

/// A role filter: forest when selected, a quiet ruled capsule otherwise, with the role's event count.
private struct RoleChip: View {
    @ScaledMetric(relativeTo: .subheadline) private var height = 34
    @Environment(\.colorSchemeContrast) private var contrast
    let title: String
    let count: Int
    let selected: Bool
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(1)
            Text(count, format: .number)
                .font(.footnote.weight(.semibold)).monospacedDigit()
                .foregroundStyle(selected ? Color.theme.onAccent.opacity(0.8) : Color.theme.secondaryText)
        }
        .foregroundStyle(selected ? Color.theme.onAccent : Color.primary)
        .padding(.horizontal, 13)
        .frame(minHeight: height)
        .background(selected ? Color.theme.accent : Color.theme.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(selected ? 0 : (contrast == .increased ? 0.45 : 0.16)), lineWidth: 0.5) }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Events per month this year: solid for months already worked, lighter for months still ahead.
struct RoleYearStrip: View {
    @ScaledMetric(relativeTo: .caption2) private var height = 30
    let focus: RolesAgenda.Focus
    let today: String
    private var currentMonth: Int { Int(today.dropFirst(5).prefix(2)) ?? 0 }
    private static let letters = Calendar.current.veryShortStandaloneMonthSymbols
    private static let names = Calendar.current.standaloneMonthSymbols

    var body: some View {
        let peak = CGFloat(max(focus.months.max() ?? 0, 1))
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<12, id: \.self) { index in
                    let count = focus.months[index]
                    RoundedRectangle(cornerRadius: 2)
                        .fill(count == 0 ? Color.primary.opacity(0.1) : Color.theme.accent.opacity(index + 1 > currentMonth ? 0.4 : 0.85))
                        .frame(height: count == 0 ? 3 : max(6, height * CGFloat(count) / peak))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { index in
                    Text(Self.letters[index])
                        .font(.caption2.weight(index + 1 == currentMonth ? .bold : .regular))
                        .foregroundStyle(index + 1 == currentMonth ? Color.theme.accent : Color.theme.secondaryText)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(focus.year) by month")
        .accessibilityValue(spoken)
    }

    private var spoken: String {
        let worked = focus.months.enumerated().filter { $0.element > 0 }.map { "\(Self.names[$0.offset]) \($0.element)" }
        return worked.isEmpty ? "No events" : worked.joined(separator: ", ")
    }
}

/// A role held on an event, as a small tinted label.
struct RoleTag: View {
    let name: String
    var body: some View {
        Text(name)
            .font(.caption.weight(.semibold)).lineLimit(1)
            .foregroundStyle(Color.theme.accent)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
