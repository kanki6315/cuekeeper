import AppIntents
import Foundation

struct CaptureExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Expense"
    static var description = IntentDescription("Save an expense draft in the background. Map available Wallet transaction details in a personal automation, then add its receipt and event later in Cuekeeper.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let supportedModes: IntentModes = .background
    @Dependency private var persistence: PersistenceController
    @Parameter(title: "Merchant") var merchant: String?
    @Parameter(title: "Amount", description: "Number only, without currency symbols or grouping separators. Unknown values can be left blank.") var amount: String?
    @Parameter(title: "Currency", description: "ISO currency code, such as USD, EUR or GBP. Leave blank if unavailable.") var currency: String?
    @Parameter(title: "Transaction date") var transactionDate: Date?
    @Parameter(title: "Transaction ID", description: "Optional stable identifier from the source transaction. Repeated deliveries with the same ID create only one draft. Leave blank if unavailable.") var transactionID: String?
    static var parameterSummary: some ParameterSummary {
        Summary("Capture an expense") { \.$merchant; \.$amount; \.$currency; \.$transactionDate; \.$transactionID }
    }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await persistence.waitUntilLoaded()
        try Task.checkCancellation()
        let input = ExpenseCaptureInput(merchant: merchant ?? "", amount: amount ?? "", currency: currency ?? "", date: transactionDate, transactionID: transactionID ?? "")
        let result = try Expense.captureBackground(input, in: persistence.container.viewContext)
        if result.inserted { await ExpenseNotifications.shared.notify(id: result.id) }
        return .result(value: result.id.uuidString)
    }
}
