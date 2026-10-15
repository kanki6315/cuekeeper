import CoreData
import Combine
import WidgetKit

extension DaySchedule {
    static func capture(in context: NSManagedObjectContext) throws -> DaySchedule {
        let request = NSFetchRequest<Job>(entityName: "Job")
        request.predicate = NSPredicate(format: "deletedAt == nil AND bookingStatus != %@", "cancelled")
        let jobs = try context.fetch(request)
        var result = DaySchedule()
        for job in jobs {
            guard let id = job.id else { continue }
            result.events.append(ScheduleEvent(id: id, title: job.eventTitle, client: job.client?.name ?? "Client to add", startDay: job.eventStartDay, endDay: job.eventEndDay, status: job.bookingStatus))
            for session in job.activeSessions {
                guard let sessionID = session.id else { continue }
                result.sessions.append(ScheduleSession(id: sessionID, eventID: id, title: session.title, day: session.day, start: session.startTime, end: session.endTime, call: session.callTime, zone: session.eventTimeZoneID, confirmed: session.scheduleStatus == "confirmed", coverage: session.coverage))
            }
        }
        result.events.sort { $0.id.uuidString < $1.id.uuidString }
        result.sessions.sort { $0.id.uuidString < $1.id.uuidString }
        return result
    }
}

@MainActor
final class SchedulePublisher: ObservableObject {
    private var observation: AnyCancellable?
    private weak var context: NSManagedObjectContext?
    private var previous: DaySchedule?
    func start(context: NSManagedObjectContext, enabled: Bool) {
        guard enabled else { return }
        self.context = context
        if observation == nil {
            observation = NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)
                .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }
        }
        refresh()
    }
    func refresh() {
        guard let context else { return }
        do {
            let snapshot = try DaySchedule.capture(in: context)
            guard snapshot != previous else { return }
            try ScheduleStore.write(snapshot)
            previous = snapshot
            WidgetCenter.shared.reloadTimelines(ofKind: ScheduleStore.widgetKind)
        } catch {
            // Leave the last complete snapshot intact; retry on the next change/activation.
            NSLog("Schedule snapshot unavailable: %@", error.localizedDescription)
        }
    }
}
