import CoreData
import Foundation

@objc(Job)
final class Job: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var name: String
    @NSManaged var startDay: String
    @NSManaged var endDay: String
    @NSManaged var bookingStatus: String
    @NSManaged var createdAt: Date?
}

/// Placeholder dates are civil dates, not UTC instants. Device travel must not move them.
enum Day {
    static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        formatter(timeZone: timeZone).string(from: date)
    }

    static func date(from value: String, timeZone: TimeZone = .current) -> Date? {
        formatter(timeZone: timeZone).date(from: value)
    }

    private static func formatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

struct JobDraft {
    var name = ""
    var startDate = Date()
    var endDate = Date()

    func save(in context: NSManagedObjectContext) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.nameRequired }
        let start = Day.string(from: startDate)
        let end = Day.string(from: endDate)
        guard start <= end else { throw ValidationError.invalidDates }
        let entity = NSEntityDescription.entity(forEntityName: "Job", in: context)!
        let job = Job(entity: entity, insertInto: context)
        job.id = UUID()
        job.name = trimmed
        job.startDay = start
        job.endDay = end
        job.bookingStatus = "tentative"
        job.createdAt = Date()
        do {
            try context.save()
        } catch {
            context.delete(job)
            throw error
        }
    }

    enum ValidationError: LocalizedError {
        case nameRequired, invalidDates
        var errorDescription: String? {
            switch self {
            case .nameRequired: return "Enter a job name."
            case .invalidDates: return "The end date must be on or after the start date."
            }
        }
    }
}
