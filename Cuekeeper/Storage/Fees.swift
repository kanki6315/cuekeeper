import CoreData
import Foundation

enum CurrencyPreferences {
    // The original seven stay first so existing pickers keep their familiar order.
    static let supported = ["USD", "EUR", "GBP", "CAD", "AUD", "NZD", "CHF",
                            "AED", "BHD", "BRL", "CNY", "CZK", "DKK", "HKD", "HUF", "ILS", "INR", "JOD", "JPY", "KRW",
                            "KWD", "MXN", "NOK", "OMR", "PLN", "SEK", "SGD", "THB", "TND", "TRY", "ZAR"]
    static let defaultDisplay = "USD,EUR"

    static func displayed(_ stored: String) -> [String] {
        let selected = Set(stored.split(separator: ",").map(String.init))
        let valid = supported.filter { selected.contains($0) }
        return valid.isEmpty ? ["USD", "EUR"] : valid
    }

    static func symbol(_ code: String) -> String {
        switch code {
        case "USD", "CAD", "AUD", "NZD", "SGD", "HKD", "MXN": "dollarsign.circle"
        case "EUR": "eurosign.circle"
        case "GBP": "sterlingsign.circle"
        case "CHF": "francsign.circle"
        case "JPY": "yensign.circle"
        case "KRW": "wonsign.circle"
        case "INR": "indianrupeesign.circle"
        default: "banknote"
        }
    }
}

/// Integer minor units are authoritative; no binary floating point in financial calculations.
/// Each currency uses its ISO 4217 minor unit, so every amount is exact in its own currency.
enum Money {
    static let limit: Int64 = 9_000_000_000_000
    static let maxDecimals = 3
    /// ISO 4217 exponents, pinned rather than read from ICU, whose display digits differ for some codes.
    static func decimals(_ currency: String) -> Int {
        switch currency {
        case "JPY", "KRW": 0
        case "BHD", "JOD", "KWD", "OMR", "TND": 3
        default: 2
        }
    }
    static func parse(_ text: String, currency: String, allowNegative: Bool = false) throws -> Int64? {
        try parse(text, decimals: decimals(currency), allowNegative: allowNegative)
    }
    static func parse(_ text: String, decimals: Int, allowNegative: Bool = false) throws -> Int64? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        if value.isEmpty { return nil }
        let fraction = decimals > 0 ? #"(\.[0-9]{1,\#(decimals)})?"# : ""
        let pattern = (allowNegative ? "^-?" : "^") + "[0-9]+" + fraction + "$"
        guard value.range(of: pattern, options: .regularExpression) != nil,
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
            let places = switch decimals { case 0: "a whole amount"; case 1: "an amount with at most one decimal place"; default: "an amount with at most \(decimals) decimal places" }
            throw RecordError.invalid("Enter \(places), without currency symbols or grouping separators.")
        }
        return try minorUnits(decimal * scale(decimals))
    }
    static func minorUnits(_ value: Decimal) throws -> Int64 {
        var value = value; var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        guard !rounded.isNaN, rounded <= Decimal(limit), rounded >= Decimal(-limit) else { throw RecordError.invalid("The amount is too large.") }
        return NSDecimalNumber(decimal: rounded).int64Value
    }
    static func text(_ amount: Int64?, currency: String) -> String {
        guard let amount else { return "" }
        // Always the currency's full places, POSIX-style, so the text round-trips through `parse`.
        let sign = amount < 0 ? "-" : ""
        let places = decimals(currency)
        let units = amount.magnitude, divisor = (0..<places).reduce(UInt64(1)) { value, _ in value * 10 }
        guard places > 0 else { return "\(sign)\(units)" }
        let fraction = String(units % divisor)
        return "\(sign)\(units / divisor).\(String(repeating: "0", count: places - fraction.count))\(fraction)"
    }
    static func format(_ amount: Int64, currency: String) -> String {
        let places = decimals(currency)
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = currency
        formatter.minimumFractionDigits = places; formatter.maximumFractionDigits = places
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(amount) / scale(places))) ?? "\(currency) \(text(amount, currency: currency))"
    }
    private static func scale(_ places: Int) -> Decimal { pow(Decimal(10), places) }
}

struct FeeLine: Codable, Equatable, Identifiable {
    var id = UUID()
    var description = ""
    var quantity = "1"
    var rate = ""
    func total(currency: String) throws -> Int64 {
        let quantity = quantity.replacingOccurrences(of: ",", with: ".")
        guard quantity.range(of: #"^[0-9]+(\.[0-9]{1,4})?$"#, options: .regularExpression) != nil,
              let count = Decimal(string: quantity, locale: Locale(identifier: "en_US_POSIX")), count > 0, count <= 1_000_000,
              let rate = try Money.parse(rate, currency: currency, allowNegative: true) else { throw RecordError.invalid("Each breakdown item needs a positive quantity and a rate. Use a negative rate for an adjustment.") }
        return try Money.minorUnits(count * Decimal(rate))
    }
}

struct FeeValue: Codable, Equatable {
    var amount: Int64?
    var currency = "USD"
    var agreement = "unknown"
    var lines: [FeeLine] = []
    func total() throws -> Int64 { try Money.minorUnits(lines.reduce(Decimal(0)) { try $0 + Decimal($1.total(currency: currency)) }) }
    func validate() throws {
        guard CurrencyPreferences.supported.contains(currency), ["unknown", "estimated", "agreed"].contains(agreement),
              amount == nil || (amount! >= 0 && amount! <= Money.limit) else { throw RecordError.invalid("Choose a supported currency, a fee agreement state, and a nonnegative fee.") }
        _ = try total()
    }
}

@objc(FeeRevision)
final class FeeRevision: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var parentsJSON: String
    @NSManaged var valueJSON: String
    @NSManaged var job: Job?
    var value: FeeValue? { try? JSONDecoder().decode(FeeValue.self, from: Data(valueJSON.utf8)) }
}

extension Job {
    func feeHeads() throws -> [FeeRevision] {
        let revisions = Array(feeRevisions ?? [])
        let ids = Set(revisions.compactMap(\.id))
        guard ids.count == revisions.count else { throw RecordError.invalid("Fee history contains missing or duplicate identities. Review sync before editing.") }
        var parents = Set<UUID>()
        for revision in revisions {
            guard revision.id != nil, let value = revision.value,
                  let prior = try? JSONDecoder().decode([UUID].self, from: Data(revision.parentsJSON.utf8)) else {
                throw RecordError.invalid("Fee history is incomplete or unreadable. Wait for sync before editing this fee.")
            }
            try value.validate()
            guard Set(prior).isSubset(of: ids) else { throw RecordError.invalid("Fee history is still syncing. Try again when this device has received the remaining revisions.") }
            parents.formUnion(prior)
        }
        let heads = revisions.filter { !parents.contains($0.id!) }.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        guard revisions.isEmpty || !heads.isEmpty else { throw RecordError.invalid("Fee history could not be resolved.") }
        return heads
    }
    /// The currency recorded on this job's direct payments. Once money is received it is the
    /// authority, so changing client or device defaults never relabels the history.
    var paymentCurrency: String? { (payments ?? []).compactMap { $0.currency.isEmpty ? nil : $0.currency }.first }
    /// A saved fee revision fixes its own currency, even with an unknown amount. With no revision
    /// there is nothing agreed, so existing payment history decides before any default.
    func currentFee() throws -> FeeValue {
        let heads = try feeHeads()
        guard heads.count <= 1 else { throw RecordError.invalid("This fee has conflicting edits. Review both versions before using it for an invoice.") }
        return heads.first?.value ?? FeeValue(currency: paymentCurrency ?? client?.defaultCurrency ?? UserDefaults.standard.string(forKey: "defaultCurrency") ?? "USD")
    }
    var feeSummary: String {
        do { let value = try currentFee(); return value.amount.map { Money.format($0, currency: value.currency) } ?? "Fee unknown" }
        catch { return "Fee needs review" }
    }
}

struct FeeDraft: Equatable {
    var amount = ""
    var currency = "USD"
    var agreement = "unknown"
    var lines: [FeeLine] = []
    var parentIDs: Set<UUID> = []
    init() { currency = UserDefaults.standard.string(forKey: "defaultCurrency") ?? "USD" }
    init(job: Job) throws {
        let value = try job.currentFee()
        self.init(value: value, parents: Set(try job.feeHeads().compactMap(\.id)))
    }
    init(value: FeeValue, parents: Set<UUID>) {
        amount = Money.text(value.amount, currency: value.currency); currency = value.currency; agreement = value.agreement; lines = value.lines; parentIDs = parents
    }
    func value() throws -> FeeValue {
        let value = FeeValue(amount: try Money.parse(amount, currency: currency), currency: currency, agreement: agreement, lines: lines)
        try value.validate(); return value
    }
    func apply(to job: Job, in writer: NSManagedObjectContext) throws {
        let heads = Set(try job.feeHeads().compactMap(\.id))
        guard heads == parentIDs else { throw RecordError.invalid("The fee changed while this editor was open. Cancel and review the latest fee; your unsaved values remain here until you close it.") }
        let value = try value()
        if let prior = job.payments?.first, prior.currency != value.currency {
            throw RecordError.invalid("This job has payment history in \(prior.currency). Its currency must stay the same.")
        }
        let revision = FeeRevision(entity: NSEntityDescription.entity(forEntityName: "FeeRevision", in: writer)!, insertInto: writer)
        revision.id = UUID(); revision.createdAt = Date(); revision.job = job
        revision.parentsJSON = String(decoding: try JSONEncoder().encode(parentIDs.sorted { $0.uuidString < $1.uuidString }), as: UTF8.self)
        revision.valueJSON = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    func save(in context: NSManagedObjectContext, jobID: NSManagedObjectID) throws {
        let writer = isolatedWriter(context)
        let job = try writer.existingObject(with: jobID) as! Job
        try apply(to: job, in: writer)
        try writer.save(); context.refreshAllObjects()
    }
}
