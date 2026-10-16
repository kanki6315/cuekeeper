import SwiftUI
import UserNotifications

struct ExpenseAutomationSettingsView: View {
    // Guide progress is user-reported, never evidence that an automation is enabled.
    @AppStorage("walletAutomationGuideStepV2") private var savedStep = 0
    @State private var shortcutsUnavailable = false
    @Environment(\.openURL) private var openURL

    private let steps: [(title: String, instruction: String)] = [
        ("Open Automation", "On the iPhone you pay with, open Shortcuts and tap Automation. Tap + to start, or edit your existing Wallet automation."),
        ("Choose your cards", "Choose Transaction, then select the cards you want to capture under When I tap."),
        ("Run automatically", "Select Run Immediately, then tap Next if shown."),
        ("Add Capture Expense", "Choose New Blank Automation. Search for Capture Expense and select Cuekeeper’s action. Expand the action to show its fields."),
        ("Connect the merchant", "Touch and hold Merchant, choose Select Variable, then Shortcut Input. Tap the inserted variable and select its merchant property."),
        ("Connect the amount", "In Amount, select Shortcut Input, then tap the variable and choose its amount property. Use the numeric amount without a currency symbol."),
        ("Connect the currency", "In Currency, select Shortcut Input, then choose its currency-code property, such as USD or EUR."),
        ("Connect the date", "In Transaction date, select Shortcut Input, then choose its transaction-date property."),
        ("Connect a transaction ID", "If Shortcut Input offers a stable transaction ID, select it for Transaction ID. Never use the card number or merchant name: repeated IDs save only one draft."),
        ("Save in Shortcuts", "Tap Done or the checkmark in Shortcuts to save your automation.")
    ]
    private var step: Int { min(max(savedStep, 0), steps.count) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if step < steps.count {
                    Text(steps[step].title).font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                    WalletSetupIllustration(step: step)
                    Text(steps[step].instruction).font(.body)
                    Button {
                        openURL(URL(string: "shortcuts://")!) { opened in
                            shortcutsUnavailable = !opened
                        }
                    } label: {
                        Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(DaybookPrimaryButton())
                    .accessibilityIdentifier("open-wallet-shortcuts")
                    if (4...8).contains(step) {
                        Text("If this property isn’t offered, skip this field.")
                            .font(.footnote).foregroundStyle(Color("SecondaryText"))
                    }
                } else {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.largeTitle).foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Check your first capture").font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("After your next card tap, look for a draft in Expenses to complete. Add its receipt and choose an event.")
                    DaybookLink("Expenses to complete") { PendingExpensesView() }
                    DaybookLink("Completion Reminders") { ExpenseAutomationRemindersView() }
                    Button("Review Setup Steps") { savedStep = 0 }.frame(minHeight: 44)
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .id(step)
        .safeAreaInset(edge: .bottom) {
            if step < steps.count {
                VStack(spacing: 16) {
                    HStack {
                        Text("Step \(step + 1) of \(steps.count)")
                            .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                        Spacer()
                        if (4...8).contains(step) {
                            Button("Skip Field") { savedStep = step + 1 }
                                .font(.subheadline).frame(minHeight: 44)
                                .accessibilityIdentifier("wallet-setup-skip-field")
                        } else {
                            ProgressView(value: Double(step + 1), total: Double(steps.count))
                                .frame(width: 100).accessibilityHidden(true)
                        }
                    }
                    HStack {
                        if step > 0 {
                            Button("Back") { savedStep = step - 1 }
                                .frame(minWidth: 44, minHeight: 44)
                                .accessibilityIdentifier("wallet-setup-back")
                        }
                        Spacer()
                        Button(step == steps.count - 1 ? "I’ve Saved It" : "Next") {
                            savedStep = step + 1
                        }
                        .buttonStyle(DaybookPrimaryButton())
                        .accessibilityIdentifier("wallet-setup-next")
                    }
                }
                .frame(maxWidth: 480).padding(.horizontal, 24)
                .padding(.top, 16).padding(.bottom, 12)
                .frame(maxWidth: .infinity).background(Color("PageBackground"))
            }
        }
        .daybookSurface()
        .navigationTitle("Wallet Automation").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { ExpenseAutomationHelpView() } label: {
                    Label("Help & Options", systemImage: "questionmark.circle")
                }.accessibilityIdentifier("wallet-setup-help")
            }
        }
        .alert("Couldn’t Open Shortcuts", isPresented: $shortcutsUnavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Open Shortcuts from your Home Screen, or reinstall Apple’s Shortcuts app from the App Store.")
        }
    }
}

/// Schematic guidance, not a screenshot or an interactive replica of Shortcuts.
private struct WalletSetupIllustration: View {
    let step: Int
    private var heading: String {
        switch step {
        case 0: "Automation"
        case 1: "Transaction"
        case 2: "When I tap"
        case 3: "New Blank Automation"
        case 4...8: "Capture Expense"
        default: "Your automation"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center) {
                    Text(heading).font(.headline)
                    Spacer(minLength: 12)
                    if step == 0 { focusIcon("plus") }
                    if step == 9 { focusIcon("checkmark") }
                }
                Divider()
                Group {
                    switch step {
                    case 0:
                        row("New Automation", icon: "plus.circle", highlighted: true)
                        row("Existing Wallet automation", icon: "creditcard", highlighted: false)
                    case 1:
                        Text("When I tap").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                        row("Your payment card", icon: "creditcard", highlighted: true, trailing: "checkmark.circle.fill")
                        Text("Select the cards you pay with").font(.subheadline)
                    case 2:
                        row("Run After Confirmation", icon: "hand.tap", highlighted: false)
                        row("Run Immediately", icon: "bolt", highlighted: true, trailing: "checkmark.circle.fill")
                    case 3:
                        Label("Capture Expense", systemImage: "magnifyingglass")
                            .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                        row("Capture Expense", icon: "tray.and.arrow.down", highlighted: true)
                        Text("Cuekeeper").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                    case 4...8:
                        Text(mappingField).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                        row("Shortcut Input", icon: "doc.text", highlighted: false)
                        Image(systemName: "arrow.down").foregroundStyle(Color("SecondaryText"))
                        row(mappingProperty, icon: "checkmark.circle", highlighted: true)
                    default:
                        row("When I tap my card", icon: "creditcard", highlighted: false)
                        Image(systemName: "arrow.down").foregroundStyle(Color("SecondaryText"))
                        row("Capture Expense", icon: "tray.and.arrow.down", highlighted: false)
                    }
                }
            }
            .padding(20).frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
            .background(Color("SurfaceBackground"), in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.16)) }
            Text("Shortcuts illustration · Labels may vary")
                .font(.caption).foregroundStyle(Color("SecondaryText"))
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
    private var mappingField: String {
        switch step {
        case 4: "Merchant"
        case 5: "Amount"
        case 6: "Currency"
        case 7: "Transaction date"
        default: "Transaction ID"
        }
    }
    private var mappingProperty: String {
        switch step {
        case 4: "Merchant property"
        case 5: "Amount property"
        case 6: "Currency code property"
        case 7: "Transaction date property"
        default: "Stable transaction ID"
        }
    }
    private func focusIcon(_ name: String) -> some View {
        Image(systemName: name).font(.headline)
            .frame(width: 44, height: 44)
            .foregroundStyle(Color("PageBackground"))
            .background(Color.accentColor, in: Circle())
    }
    private func row(_ title: String, icon: String, highlighted: Bool, trailing: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            if let trailing { Image(systemName: trailing) }
        }
        .font(.body).padding(14)
        .foregroundStyle(highlighted ? Color.accentColor : Color("SecondaryText"))
        .background(highlighted ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if highlighted { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2) }
        }
    }
}

private struct ExpenseAutomationHelpView: View {
    @AppStorage(ExpenseShortcutActivity.lastSuccessKey) private var lastCapture = 0.0

    var body: some View {
        DaybookForm {
            Section {
                DaybookLink("Include Payment Details") { ExpenseAutomationPaymentDetailsView() }
                DaybookLink("Completion Reminders") { ExpenseAutomationRemindersView() }
            }
            Section("Capture activity on this device") {
                if lastCapture > 0 {
                    Text("Last successful run: \(Date(timeIntervalSince1970: lastCapture).formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("No Capture Expense run recorded yet")
                }
                Text("Cuekeeper can’t check whether your Wallet automation exists or is enabled. Runs from Siri and manual shortcuts also appear here. Older runs may not be recorded.")
                    .foregroundStyle(Color("SecondaryText"))
            }
            Section {
                DisclosureGroup("No draft after a purchase?") {
                    Text("In Shortcuts → Automation, check that your Transaction automation is enabled, uses the card you paid with, and runs immediately.")
                    Text("Check that it contains Cuekeeper’s Capture Expense action. If Shortcuts reports a field error, clear the optional fields and try again. Your phone may need to be unlocked to access saved data.")
                }
                DisclosureGroup("Getting duplicate drafts?") {
                    Text("Keep one automation with one Capture Expense action for each card. Edit an existing automation instead of adding another.")
                    Text("Two runs can create two drafts and reminders. A matching stable Transaction ID prevents repeat deliveries creating extra drafts on this device. Without it, each run creates a separate draft.")
                }
                DisclosureGroup("Which payments are captured?") {
                    Text("This automation responds to Wallet card taps, not every card charge. Online payments, physical-card purchases and payments on other devices may not trigger it.")
                    Text("If Transaction isn’t offered, set this up on a compatible iPhone with a payment card in Wallet.")
                }
                DisclosureGroup("Use the Action Button instead") {
                    Text("Choose Scan Receipt for the Action Button. It opens Cuekeeper so you can choose an event and scan a receipt.")
                }
            }
        }.navigationTitle("Help & Options").navigationBarTitleDisplayMode(.inline)
    }
}

private struct ExpenseAutomationPaymentDetailsView: View {
    var body: some View {
        DaybookForm {
            Section {
                Text("Connect each field to a property of Shortcut Input so it changes with every payment. Leave only unavailable details blank.")
                Text("In Shortcuts, edit your automation and expand Capture Expense to see its fields.")
            }
            Section("Merchant") {
                Text("Touch and hold Merchant, choose Select Variable, then Shortcut Input. Tap the inserted variable and choose its merchant property, if offered.")
            }
            Section("Amount and currency") {
                Text("Repeat for Amount using the amount property. Use a number without a currency symbol. For Currency, select a currency-code property such as USD or EUR, if available.")
            }
            Section("Date and transaction ID") {
                Text("For Transaction date, choose the matching date property if available.")
                Text("Only fill Transaction ID if the input offers a stable transaction identifier. Don’t use the card number or merchant name: repeated IDs save only one draft.")
            }
        }.navigationTitle("Payment Details").navigationBarTitleDisplayMode(.inline)
    }
}

private struct ExpenseAutomationRemindersView: View {
    var body: some View {
        DaybookForm { ExpenseRemindersSection() }
            .navigationTitle("Completion Reminders").navigationBarTitleDisplayMode(.inline)
    }
}

/// Shared so reminders can be turned on where drafts are reviewed, not only from Wallet setup help.
struct ExpenseRemindersSection: View {
    var header: String?
    @AppStorage(ExpenseNotifications.preference) private var enabled = false
    @ObservedObject private var notifications = ExpenseNotifications.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    @State private var requesting = false

    var body: some View {
        Section {
            Text("Get a notification that opens your captured draft. Drafts remain in Upcoming and Payments when reminders are off.")
            if enabled {
                Button("Turn Off Reminders") { Task { await notifications.disable() } }
            }
            if notifications.status == .denied {
                Text("Notifications are disabled in device Settings.")
                Button("Open Notification Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } else if !enabled {
                Button("Enable Reminders") {
                    requesting = true
                    Task { await notifications.enable(); requesting = false }
                }.disabled(requesting).accessibilityIdentifier("enable-expense-reminders")
            }
            if requesting { ProgressView("Requesting permission…") }
            if let error = notifications.lastError { Text(error).foregroundStyle(Color("SecondaryText")) }
        } header: {
            if let header { Text(header) }
        }
        .task { await notifications.refresh() }
        .onChange(of: phase) { _, value in
            if value == .active { Task { await notifications.refresh() } }
        }
    }
}
