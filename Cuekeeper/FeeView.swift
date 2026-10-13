import CoreData
import SwiftUI

struct FeeFields: View {
    @Binding var draft: FeeDraft
    var body: some View {
        TextField("Overall fee (unknown if blank)", text: $draft.amount).keyboardType(.decimalPad).accessibilityIdentifier("overall-fee")
        Picker("Currency", selection: $draft.currency) { Text("USD").tag("USD"); Text("EUR").tag("EUR") }
        Picker("Agreement", selection: $draft.agreement) {
            Text("Unknown").tag("unknown"); Text("Estimated").tag("estimated"); Text("Agreed").tag("agreed")
        }
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
            Form {
                Section { FeeFields(draft: $draft) } header: { Text("Overall fee") } footer: {
                    Text("Leave the amount blank if it’s unknown. Enter 0 for explicitly unpaid work. Changing the breakdown never changes this amount automatically.")
                }
                Section {
                    ForEach($draft.lines) { $line in
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Description", text: $line.description)
                            TextField("Quantity", text: $line.quantity).keyboardType(.decimalPad)
                            TextField("Rate (negative for adjustments)", text: $line.rate).keyboardType(.numbersAndPunctuation)
                            if let total = try? line.total() { Text(Money.format(total, currency: draft.currency)).font(.subheadline).foregroundStyle(.secondary) }
                            Button("Remove Item", role: .destructive) { draft.lines.removeAll { $0.id == line.id } }
                        }.padding(.vertical, 4)
                    }
                    Button("Add Breakdown Item", systemImage: "plus") { draft.lines.append(FeeLine()) }.accessibilityIdentifier("add-fee-item")
                    if !draft.lines.isEmpty {
                        if let sum = try? FeeValue(lines: draft.lines).total() {
                            LabeledContent("Breakdown total", value: Money.format(sum, currency: draft.currency))
                            if (try? Money.parse(draft.amount)) != sum { Text("The breakdown differs from the overall fee.").foregroundStyle(.secondary) }
                            Button("Use Breakdown Total") {
                                guard sum >= 0 else { error = "The overall fee cannot be negative."; return }
                                draft.amount = Money.text(sum)
                            }
                        } else { Text("Complete each quantity and rate to calculate the breakdown.").foregroundStyle(.secondary) }
                    }
                } header: { Text("Optional breakdown") }
            }
            .navigationTitle("Edit Fee").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if draft != initial { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try draft.save(in: context, jobID: job.objectID); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("save-fee")
                }
            }
            .saveErrorAlert($error).interactiveDismissDisabled(draft != initial)
            .confirmationDialog("Discard changes?", isPresented: $discard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }; Button("Keep Editing", role: .cancel) {}
            }
        }
    }
}

private struct PresentedFee: Identifiable {
    let id = UUID()
    let draft: FeeDraft
}

struct FeeDetailView: View {
    @ObservedObject var job: Job
    @State private var editing: PresentedFee?
    @State private var error: String?
    private var revisions: [FeeRevision] { (job.feeRevisions ?? []).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) } }
    var body: some View {
        Form {
            Section("Overall fee") {
                Text(job.feeSummary).font(.title2).monospacedDigit()
                if let value = try? job.currentFee() {
                    LabeledContent("Agreement", value: value.agreement.capitalized)
                    if !value.lines.isEmpty {
                        ForEach(value.lines) { line in
                            LabeledContent(line.description.isEmpty ? "Breakdown item" : line.description, value: (try? line.total()).map { Money.format($0, currency: value.currency) } ?? "Incomplete")
                        }
                        if let total = try? value.total(), total != value.amount { Text("Breakdown total: \(Money.format(total, currency: value.currency)). The overall fee remains unchanged.").foregroundStyle(.secondary) }
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
                                    Text("\(value.agreement.capitalized) · \(value.lines.count) breakdown items").font(.subheadline)
                                    Text(revision.createdAt?.formatted() ?? "Date unknown").font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            Section("Fee history") {
                if revisions.isEmpty { Text("No fee entered yet").foregroundStyle(.secondary) }
                ForEach(revisions, id: \.objectID) { revision in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(revision.value?.amount.map { Money.format($0, currency: revision.value!.currency) } ?? "Unknown fee")
                        Text(revision.createdAt?.formatted() ?? "Date unknown").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Fee").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { FeeEditorView(job: job, draft: $0.draft) }
        .saveErrorAlert($error)
    }
    private func openEditor() {
        do { editing = PresentedFee(draft: try FeeDraft(job: job)) }
        catch { self.error = error.localizedDescription }
    }
}
