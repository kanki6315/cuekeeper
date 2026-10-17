import SwiftUI
import UserNotifications

struct ExpenseAutomationSettingsView: View {
    private static let shortcutURL = URL(string: "https://www.icloud.com/shortcuts/7fcd1ee447d343d59ac8ff14dcaaf10e")!
    @Environment(\.openURL) private var openURL
    @Environment(\.openExpensesInbox) private var openInbox
    @State private var linkUnavailable = false

    var body: some View {
        DaybookForm {
            Section {
                Text("Capture tap-to-pay expenses")
                    .font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Button {
                    openURL(Self.shortcutURL) { opened in
                        linkUnavailable = !opened
                    }
                } label: {
                    Label("Add Capture Expense Shortcut", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(DaybookPrimaryButton())
                .accessibilityIdentifier("install-wallet-shortcut")
            }
            Section("Finish in Shortcuts") {
                Text("Choose your cards, select Run Immediately, then save.")
            }
            Section {
                DaybookLink("Set Up Manually") { ExpenseAutomationManualSetupView() }
                    .accessibilityIdentifier("wallet-manual-setup")
                if let openInbox {
                    DaybookActionRow("Open Expenses Inbox", systemImage: "tray") { openInbox() }
                        .accessibilityIdentifier("wallet-open-inbox")
                }
            } footer: {
                Text("After your next card tap, check the Expenses inbox for a draft.")
            }
        }
        .navigationTitle("Wallet Automation").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { ExpenseAutomationHelpView() } label: {
                    Label("Help & Options", systemImage: "questionmark.circle")
                }.accessibilityIdentifier("wallet-setup-help")
            }
        }
        .alert("Couldn’t Open Shortcut Link", isPresented: $linkUnavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Try again with an internet connection, or use Set Up Manually to create the automation in Shortcuts.")
        }
    }
}

private struct ExpenseAutomationManualSetupView: View {
    @State private var shortcutsUnavailable = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Shortcuts → Automation → + → Transaction. Choose your cards and Run Immediately.")
                // Show only the actions, omitting the status bar, header and empty lower canvas.
                GeometryReader { geometry in
                    Image("WalletAutomationExample")
                        .resizable()
                        .frame(width: geometry.size.width, height: geometry.size.width * 1280.0 / 589.0)
                        .offset(y: -geometry.size.width * 160.0 / 589.0)
                        .frame(height: geometry.size.height, alignment: .top)
                        .clipped()
                }
                    .aspectRatio(589.0 / 600.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 280)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityLabel("Completed automation: When Any Card is tapped, Current Date, then Cuekeeper’s Capture Expense action.")
                    .accessibilityIdentifier("wallet-setup-example")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add Current Date, then Capture Expense.")
                        .font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("Merchant → transaction’s Merchant")
                    Text("Amount → transaction’s Amount")
                    Text("Transaction date → Current Date output")
                    Text("If you know the currency, enter its three-letter code (e.g. USD). Otherwise, leave it blank. Leave Transaction ID blank, then save.")
                        .foregroundStyle(Color.theme.secondaryText)
                }
                .accessibilityIdentifier("wallet-setup-mappings")
            }
            .font(.subheadline)
            .frame(maxWidth: 480, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
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
            .frame(maxWidth: 480).padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: .infinity).background(Color.theme.page)
        }
        .daybookSurface()
        .navigationTitle("Set Up Manually").navigationBarTitleDisplayMode(.inline)
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
                    .foregroundStyle(Color.theme.secondaryText)
            }
            Section {
                DisclosureGroup("Installing the shared shortcut") {
                    Text("Open the install link on the iPhone you pay with, review the shortcut and add your copy. Merchant, amount and the current date are already connected.")
                    Text("Choose your cards under When I tap, select Run Immediately and save. If the trigger isn’t included after import, use Set Up Manually on the Wallet Automation screen.")
                    Text("Cuekeeper can’t verify that the shortcut was installed or enabled. Check Expenses after your next card tap.")
                }
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
                Text("For Transaction date, add a Date action set to Current Date before Capture Expense and select its Date output. This records the capture time. Leave the field blank if you don’t want to use the capture time.")
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
            Text("Get a notification that opens your captured draft. With reminders off, drafts wait in the Expenses inbox.")
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
            if let error = notifications.lastError { Text(error).foregroundStyle(Color.theme.secondaryText) }
        } header: {
            if let header { Text(header) }
        }
        .task { await notifications.refresh() }
        .onChange(of: phase) { _, value in
            if value == .active { Task { await notifications.refresh() } }
        }
    }
}
