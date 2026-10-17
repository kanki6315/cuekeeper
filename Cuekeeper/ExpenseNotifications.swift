import Combine
import CoreData
import Foundation
import UserNotifications

@MainActor
protocol ExpenseNotificationDelivering {
    func authorization() async -> UNAuthorizationStatus
    func requestPermission() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func identifiers() async -> [String]
    func remove(_ identifiers: [String])
}

@MainActor
final class SystemExpenseNotifications: ExpenseNotificationDelivering {
    private let center = UNUserNotificationCenter.current()
    private let removalQueue = DispatchQueue(label: "Cuekeeper.expense-notification-removal", qos: .utility)
    private let removeNotifications: @Sendable ([String]) -> Void

    init(removeNotifications: (@Sendable ([String]) -> Void)? = nil) {
        let center = center
        self.removeNotifications = removeNotifications ?? { identifiers in
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }
    func authorization() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func requestPermission() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func identifiers() async -> [String] {
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map { $0.request.identifier }
        return Array(Set(pending + delivered))
    }
    func remove(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        // These void-returning APIs can synchronously wait on the notification
        // service. Keep that IPC off the UI thread when saving or opening a receipt.
        let removeNotifications = removeNotifications
        removalQueue.async {
            removeNotifications(identifiers)
        }
    }
}

@MainActor
final class ExpenseNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = ExpenseNotifications()
    static let preference = "expenseRemindersEnabled"
    static let prefix = "expense-draft-"
    struct Route: Identifiable { let id: UUID }
    @Published var route: Route?
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?
    /// Permission messages describe the authorization status and go stale when it changes in Settings;
    /// delivery failures stay until a reminder is delivered.
    private enum ErrorKind { case permission, delivery }
    private var lastErrorKind: ErrorKind?
    private let delivery: ExpenseNotificationDelivering
    private let defaults: UserDefaults
    init(delivery: ExpenseNotificationDelivering? = nil, defaults: UserDefaults = .standard) {
        self.delivery = delivery ?? SystemExpenseNotifications(); self.defaults = defaults
        super.init()
    }
    func installDelegate() { UNUserNotificationCenter.current().delegate = self }
    func refresh() async {
        status = await delivery.authorization()
        if lastErrorKind == .permission, Self.permits(status) { setError(nil) }
    }
    func enable() async {
        do {
            let allowed = try await delivery.requestPermission()
            defaults.set(allowed, forKey: Self.preference)
            if allowed { if lastErrorKind == .permission { setError(nil) } }
            else { setError("Notifications are disabled. You can still complete expenses from Upcoming or Payments.", kind: .permission) }
        } catch { setError("Couldn’t enable reminders. Try again in Settings.", kind: .permission) }
        await refresh()
    }
    private func setError(_ message: String?, kind: ErrorKind? = nil) {
        lastError = message; lastErrorKind = message == nil ? nil : kind
    }
    private static func permits(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }
    func disable() async {
        defaults.set(false, forKey: Self.preference)
        delivery.remove(await delivery.identifiers().filter { $0.hasPrefix(Self.prefix) })
    }
    static func request(id: UUID) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Expense saved for review"
        content.body = "Add a receipt and choose an event to complete your expense."
        content.sound = .default; content.threadIdentifier = "expense-drafts"
        content.userInfo = ["expenseID": id.uuidString]
        return UNNotificationRequest(identifier: prefix + id.uuidString, content: content, trigger: nil)
    }
    /// Saving the draft is authoritative. Notification denial/failure never rolls it back.
    func notify(id: UUID) async {
        guard defaults.bool(forKey: Self.preference) else { return }
        guard Self.permits(await delivery.authorization()) else { return }
        do { try await delivery.add(Self.request(id: id)); setError(nil) }
        catch { setError("A reminder couldn’t be delivered. Your expense is saved in Expenses to complete.", kind: .delivery) }
    }
    func clear(id: UUID) { delivery.remove([Self.prefix + id.uuidString]) }
    func reconcile(in context: NSManagedObjectContext) async {
        // Do not create reminders on sync: only the capturing device notifies.
        guard let expenses = try? context.fetch(NSFetchRequest<Expense>(entityName: "Expense")) else { return }
        let active = Set(expenses.filter(\.needsCompletion).compactMap(\.id).map { Self.prefix + $0.uuidString })
        let stale = await delivery.identifiers().filter { $0.hasPrefix(Self.prefix) && !active.contains($0) }
        delivery.remove(stale)
    }
    func open(userInfo: [AnyHashable: Any]) {
        guard let value = userInfo["expenseID"] as? String, let id = UUID(uuidString: value) else { return }
        route = Route(id: id)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        Task { @MainActor in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier { self.open(userInfo: info) }
            completionHandler()
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The in-app pending-expense prompt handles foreground capture.
        completionHandler([])
    }
}
