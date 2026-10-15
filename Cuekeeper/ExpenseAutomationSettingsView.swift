import SwiftUI
import UserNotifications

struct ExpenseAutomationSettingsView: View {
    @AppStorage(ExpenseNotifications.preference) private var enabled = false
    @ObservedObject private var notifications = ExpenseNotifications.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    @State private var requesting = false
    var body: some View {
        DaybookForm {
            Section {
                Text("Capture now, finish later").font(.title2.bold())
                Text("A Wallet automation can save a draft after you tap to pay. Add its receipt and event when you next open Cuekeeper.").foregroundStyle(Color("SecondaryText"))
            }.containerValue(\.daybookUnframed, true)
            Section("Set up in Shortcuts") {
                step(1, "Open Shortcuts → Automation → +.")
                step(2, "Choose Transaction or Wallet, then select the cards under When I tap.")
                step(3, "Select Run Immediately, then Next.")
                step(4, "Create a blank automation and add Cuekeeper → Capture Expense.")
                step(5, "For Merchant, Amount, Currency and Transaction date, select Shortcut Input and the matching property where available. Leave missing fields blank. Amount should contain only a number; currency should be a code such as USD or EUR.")
                step(6, "If the transaction provides a stable Transaction ID, map it too. This prevents repeated deliveries of that ID creating duplicates. Otherwise leave it blank; separate captures will remain separate drafts.")
                step(7, "Save the automation. Check your next purchase in Expenses to complete, then attach its receipt and choose an event.")
            }
            Section("Completion reminders") {
                Text("Optional notifications open the captured draft. Drafts remain in Upcoming and Payments even when notifications are off.").foregroundStyle(Color("SecondaryText"))
                if enabled {
                    Button("Turn Off Reminders") { Task { await notifications.disable() } }
                }
                if notifications.status == .denied {
                    Text("Notifications are disabled in iPhone Settings.")
                    Button("Open Notification Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                } else if !enabled {
                    Button("Enable Reminders") {
                        requesting = true
                        Task { await notifications.enable(); requesting = false }
                    }.disabled(requesting).accessibilityIdentifier("enable-expense-reminders")
                }
                if requesting { ProgressView("Requesting permission…") }
                if let error = notifications.lastError { Text(error).foregroundStyle(Color("SecondaryText")) }
            }
            Section("What to expect") {
                Text("This automation responds to Wallet card taps. Transaction fields vary by card and system version; it is not a feed of every card charge. Your phone may need to be unlocked for the action to access its saved data.")
                Text("Cuekeeper saves a draft first. Notifications depend on your permission and Focus settings. Receipt extraction fills missing fields and asks you to review differences from the captured payment.")
                Text("For the Action Button, choose Scan Receipt instead. That action opens Cuekeeper immediately so you can choose an event and scan.")
            }
        }.navigationTitle("Wallet Automation").navigationBarTitleDisplayMode(.inline)
            .task { await notifications.refresh() }
            .onChange(of: phase) { _, value in if value == .active { Task { await notifications.refresh() } } }
    }
    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number).").monospacedDigit().foregroundStyle(Color("SecondaryText"))
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
