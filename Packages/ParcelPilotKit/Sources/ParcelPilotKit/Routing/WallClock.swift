import Foundation

/// Converts route-local wall-clock times to instants.
///
/// A time is stored as minutes after local midnight of the route's service date, in the route's IANA
/// time zone. Values ≥ 1440 are on the following day(s), which is how windows that cross midnight are
/// expressed. Wall-clock semantics are used (02:30 means the clock reading 02:30), and two DST edge
/// cases are resolved explicitly — the same policy is implemented in the Cloud Functions and tested
/// against the shared fixture `fixtures/shared/timezone-cases.json`:
///
/// * Nonexistent local time (spring-forward gap): shifted forward by the gap (02:30 → 03:30).
/// * Ambiguous local time (fall-back overlap): the earlier instant (first occurrence) is used.
public enum WallClock {
    public struct ServiceDate: Codable, Hashable, Sendable {
        public var year: Int
        public var month: Int
        public var day: Int

        public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }

        public init?(iso: String) {
            let parts = iso.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
            self.init(year: parts[0], month: parts[1], day: parts[2])
            // Reject impossible dates such as 2026-02-30.
            guard let roundTrip = adding(days: 0), roundTrip == self else { return nil }
        }

        public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

        /// Calendar arithmetic on the civil date (time-zone independent).
        public func adding(days: Int) -> ServiceDate? {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            guard let base = utc.date(from: DateComponents(year: year, month: month, day: day)),
                  let moved = utc.date(byAdding: .day, value: days, to: base) else { return nil }
            let c = utc.dateComponents([.year, .month, .day], from: moved)
            return ServiceDate(year: c.year!, month: c.month!, day: c.day!)
        }

        public static func today(in timeZone: TimeZone, now: Date = Date()) -> ServiceDate {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let c = cal.dateComponents([.year, .month, .day], from: now)
            return ServiceDate(year: c.year!, month: c.month!, day: c.day!)
        }
    }

    public enum Resolution: String, Codable, Sendable {
        case exact, shiftedForwardFromGap, earlierOfAmbiguous
    }

    /// Instant for `minute` on `serviceDate` in `timeZone`.
    public static func instant(serviceDate: ServiceDate, minute: Int, timeZone: TimeZone) -> (date: Date, resolution: Resolution) {
        precondition(minute >= 0, "wall-clock minutes are non-negative")
        let dayOffset = minute / 1440
        let minuteOfDay = minute % 1440
        let date = serviceDate.adding(days: dayOffset) ?? serviceDate
        // Seconds since epoch if the wall-clock reading were UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let localAsUTC = utc.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: minuteOfDay / 60, minute: minuteOfDay % 60))!.timeIntervalSince1970

        // Offsets in effect a day either side cover any single transition (true for Canadian zones).
        let before = TimeInterval(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: localAsUTC - 86_400)))
        let after = TimeInterval(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: localAsUTC + 86_400)))
        var valid: [TimeInterval] = []
        for offset in Set([before, after]) {
            let candidate = localAsUTC - offset
            if TimeInterval(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: candidate))) == offset {
                valid.append(candidate)
            }
        }
        if valid.count == 1 { return (Date(timeIntervalSince1970: valid[0]), .exact) }
        if valid.count > 1 { return (Date(timeIntervalSince1970: valid.min()!), .earlierOfAmbiguous) }
        // Gap: interpret with the offset in effect before the transition → lands after the gap.
        return (Date(timeIntervalSince1970: localAsUTC - before), .shiftedForwardFromGap)
    }

    public static func instant(route: Route, minute: Int) -> Date? {
        guard let date = ServiceDate(iso: route.serviceDate) else { return nil }
        return instant(serviceDate: date, minute: minute, timeZone: route.timeZone).date
    }

    /// Wall-clock minutes (relative to the service date) for an instant, in the given zone.
    public static func minute(of instant: Date, serviceDate: ServiceDate, timeZone: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day0 = utc.date(from: DateComponents(year: serviceDate.year, month: serviceDate.month, day: serviceDate.day))!
        let dayN = utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day))!
        let days = Int((dayN.timeIntervalSince(day0) / 86_400).rounded())
        return days * 1440 + (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// "9:05 AM", with "(+1 day)" for next-day minutes. Uses a fixed en-CA style for consistency.
    public static func label(_ minute: Int) -> String {
        let day = minute / 1440
        let m = minute % 1440
        let h = m / 60, mm = m % 60
        let suffix = h < 12 ? "AM" : "PM"
        let h12 = h % 12 == 0 ? 12 : h % 12
        let base = String(format: "%d:%02d %@", h12, mm, suffix)
        return day > 0 ? "\(base) (+\(day) day)" : base
    }

    public static func rfc3339(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// Canadian time zones offered when creating a route.
    public static let canadianTimeZones: [(id: String, label: String)] = [
        ("America/St_Johns", "Newfoundland (St. John's)"),
        ("America/Halifax", "Atlantic (Halifax)"),
        ("America/Moncton", "Atlantic (Moncton)"),
        ("America/Glace_Bay", "Atlantic (Glace Bay)"),
        ("America/Goose_Bay", "Atlantic (Goose Bay)"),
        ("America/Blanc-Sablon", "Atlantic, no DST (Blanc-Sablon)"),
        ("America/Toronto", "Eastern (Toronto, Montréal, Ottawa)"),
        ("America/Iqaluit", "Eastern (Iqaluit)"),
        ("America/Atikokan", "Eastern, no DST (Atikokan)"),
        ("America/Winnipeg", "Central (Winnipeg)"),
        ("America/Rankin_Inlet", "Central (Rankin Inlet)"),
        ("America/Resolute", "Central (Resolute)"),
        ("America/Regina", "Central, no DST (Regina, Saskatchewan)"),
        ("America/Swift_Current", "Central, no DST (Swift Current)"),
        ("America/Edmonton", "Mountain (Edmonton, Calgary)"),
        ("America/Cambridge_Bay", "Mountain (Cambridge Bay)"),
        ("America/Inuvik", "Mountain (Inuvik)"),
        ("America/Yellowknife", "Mountain (Yellowknife)"),
        ("America/Creston", "Mountain, no DST (Creston)"),
        ("America/Dawson_Creek", "Mountain, no DST (Dawson Creek)"),
        ("America/Fort_Nelson", "Mountain, no DST (Fort Nelson)"),
        ("America/Whitehorse", "Yukon (Whitehorse)"),
        ("America/Dawson", "Yukon (Dawson)"),
        ("America/Vancouver", "Pacific (Vancouver, Victoria)"),
    ]
}
