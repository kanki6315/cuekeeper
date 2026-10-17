import CoreData
import SwiftUI

struct FeeFields: View {
    @Binding var draft: FeeDraft
    var body: some View {
        DaybookTextField("Overall fee (unknown if blank)", text: $draft.amount).keyboardType(.decimalPad).accessibilityIdentifier("overall-fee")
        DaybookPicker("Currency", selection: $draft.currency) { ForEach(CurrencyPreferences.supported, id: \.self) { Text($0).tag($0) } }
        DaybookPicker("Agreement", selection: $draft.agreement) {
            Text("Unknown").tag("unknown"); Text("Estimated").tag("estimated"); Text("Agreed").tag("agreed")
        }
    }
}

struct FeeEditingFields: View {
    @Binding var draft: FeeDraft
    @State private var error: String?
    var body: some View {
        Group {
                Section { FeeFields(draft: $draft) } header: { Text("Overall fee") } footer: {
                    Text("Leave the amount blank until it’s agreed; a blank fee is never counted as zero. Enter 0 for unpaid work. Changing the breakdown never changes this amount automatically.")
                }
                Section {
                    ForEach($draft.lines) { $line in
                        VStack(alignment: .leading, spacing: 10) {
                            DaybookTextField("Description", text: $line.description)
                            HStack(alignment: .bottom, spacing: 16) {
                                VStack(alignment: .leading, spacing: 6) { Text("Quantity").font(.caption).foregroundStyle(Color("SecondaryText")); DaybookTextField("Quantity", text: $line.quantity).keyboardType(.decimalPad) }.frame(maxWidth: 80)
                                Text("×").foregroundStyle(Color("SecondaryText"))
                                VStack(alignment: .leading, spacing: 6) { Text("Rate").font(.caption).foregroundStyle(Color("SecondaryText")); DaybookTextField("Rate (negative for adjustments)", text: $line.rate).keyboardType(.numbersAndPunctuation) }
                                if let total = try? line.total(currency: draft.currency, typedIn: .current) { Text(Money.format(total, currency: draft.currency)).font(.subheadline.weight(.semibold)).monospacedDigit() }
                            }
                            Button("Remove Item", role: .destructive) { draft.lines.removeAll { $0.id == line.id } }
                        }.padding(.vertical, 4)
                    }
                    Button("Add Breakdown Item", systemImage: "plus") { draft.lines.append(FeeLine()) }.accessibilityIdentifier("add-fee-item")
                    if !draft.lines.isEmpty {
                        if let sum = try? FeeValue(currency: draft.currency, lines: draft.lines).total(typedIn: .current) {
                            LabeledContent("Breakdown total", value: Money.format(sum, currency: draft.currency))
                            if (try? Money.parseInput(draft.amount, currency: draft.currency)) != sum {
                                Label {
                                    if let amount = try? Money.parseInput(draft.amount, currency: draft.currency), let delta = try? Money.minorUnits(Decimal(sum) - Decimal(amount)) {
                                        Text("Breakdown is \(Money.format(abs(delta), currency: draft.currency)) \(delta > 0 ? "above" : "below") the overall fee.")
                                    } else { Text("The overall fee hasn’t been set.") }
                                } icon: { Image(systemName: "exclamationmark.circle") }
                                    .font(.subheadline).foregroundStyle(Color("AmberText"))
                            }
                            Button("Use Breakdown Total") {
                                guard sum >= 0 else { error = "The overall fee cannot be negative."; return }
                                draft.amount = Money.inputText(sum, currency: draft.currency)
                            }
                        } else { Text("Complete each quantity and rate to calculate the breakdown.").foregroundStyle(Color("SecondaryText")) }
                    }
                } header: { Text("Optional breakdown") }
        }.saveErrorAlert($error)
    }
}

struct FeeEditorView: View {
    let job: Job
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FeeDraft
    @State private var initial: FeeDraft
    @State private var error: String?
    @State private var discard = false
    init(job: Job, draft: FeeDraft) {
        self.job = job; _draft = State(initialValue: draft); _initial = State(initialValue: draft)
    }
    var body: some View {
        NavigationStack {
            DaybookForm(title: job.displayName, subtitle: "Fee & breakdown") {
                FeeEditingFields(draft: $draft)
            }
            .navigationTitle("Edit Fee").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if draft != initial { discard = true } else { dismiss() } }
                        .confirmationDialog("Discard changes?", isPresented: $discard, titleVisibility: .visible) {
                            Button("Discard Changes", role: .destructive) { dismiss() }
                            Button("Keep Editing", role: .cancel) {}
                        }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try draft.save(in: context, jobID: job.objectID); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("save-fee")
                }
            }
            .saveErrorAlert($error).interactiveDismissDisabled(draft != initial)
            .preservesDraftOnTodayLink()
        }
        .presentationSizing(.page)
        .presentationDetents([.large])
        .presentationBackground(Color("PageBackground"))
    }
}

private struct PresentedFee: Identifiable {
    let id = UUID()
    let draft: FeeDraft
}

struct FeeDetailView: View {
    @ObservedObject var job: Job
    @State private var editing: PresentedFee?
    @State private var editingEvent = false
    @State private var error: String?
    private var revisions: [FeeRevision] { (job.feeRevisions ?? []).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) } }
    var body: some View {
        DaybookForm(title: job.displayName, subtitle: "Fee & breakdown") {
            Section("Overall fee") {
                Text(job.feeSummary).font(.title2).monospacedDigit()
                if let value = try? job.currentFee() {
                    LabeledContent("Agreement", value: value.agreement.capitalized)
                    if !value.lines.isEmpty {
                        ForEach(value.lines) { line in
                            LabeledContent(line.description.isEmpty ? "Breakdown item" : line.description, value: (try? line.total(currency: value.currency)).map { Money.format($0, currency: value.currency) } ?? "Incomplete")
                        }
                        if let total = try? value.total(), total != value.amount { Text("Breakdown total: \(Money.format(total, currency: value.currency)). The overall fee remains unchanged.").foregroundStyle(Color("SecondaryText")) }
                    }
                    Button("Edit Fee & Breakdown") { openEditor() }.accessibilityIdentifier("edit-fee")
                } else {
                    Text("Concurrent or incomplete fee history needs review. No version has been discarded.")
                }
            }
            if let heads = try? job.feeHeads(), heads.count > 1 {
                Section("Resolve conflicting edits") {
                    ForEach(heads, id: \.objectID) { revision in
                        if let value = revision.value {
                            Button {
                                editing = PresentedFee(draft: FeeDraft(value: value, parents: Set(heads.compactMap(\.id))))
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(value.amount.map { Money.format($0, currency: value.currency) } ?? "Unknown fee")
                                    Text("\(value.agreement.capitalized) · \(counted(value.lines.count, "breakdown item", "breakdown items"))").font(.subheadline)
                                    Text(revision.createdAt?.formatted() ?? "Date unknown").font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            Section("Fee history") {
                if revisions.isEmpty { Text("No fee entered yet").foregroundStyle(Color("SecondaryText")) }
                ForEach(revisions, id: \.objectID) { revision in
                    DisclosureGroup(revision.createdAt?.formatted() ?? "Date unknown") {
                        if let value = revision.value {
                            Text(value.amount.map { Money.format($0, currency: value.currency) } ?? "Unknown fee")
                            Text(value.agreement.capitalized)
                            ForEach(value.lines) { line in
                                LabeledContent(line.description.isEmpty ? "Breakdown item" : line.description, value: (try? line.total(currency: value.currency)).map { Money.format($0, currency: value.currency) } ?? "Incomplete")
                                Text("\(line.quantity) × \(line.rate)").font(.caption)
                            }
                        } else { Text("This revision is incomplete or unreadable.") }
                    }
                }
            }
        }
        .navigationTitle("Fee").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { FeeEditorView(job: job, draft: $0.draft) }
        .sheet(isPresented: $editingEvent) { EventEditorView(anchor: job, focusBooking: job.objectID, focusFee: true) }
        .saveErrorAlert($error)
    }
    private func openEditor() {
        do { _ = try FeeDraft(job: job); editingEvent = true }
        catch { self.error = error.localizedDescription }
    }
}
