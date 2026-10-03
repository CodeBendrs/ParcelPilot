import Foundation

public enum DisplayFormat {
    public static func distance(meters: Double, unit: DistanceUnit) -> String {
        switch unit {
        case .kilometres:
            if meters < 1000 { return "\(Int(meters.rounded())) m" }
            return String(format: meters < 10_000 ? "%.1f km" : "%.0f km", meters / 1000)
        case .miles:
            let miles = meters / 1609.344
            if miles < 0.1 { return "\(Int((meters * 3.28084).rounded())) ft" }
            return String(format: miles < 10 ? "%.1f mi" : "%.0f mi", miles)
        }
    }

    public static func duration(seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600 + 30) / 60
        if h == 0 { return "\(max(m, s > 0 ? 1 : 0)) min" }
        if m == 60 { return "\(h + 1) h" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    public static func time(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    public static func dateTime(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.timeZone = timeZone
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: date)
    }

    public static func serviceDuration(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        let m = seconds / 60, s = seconds % 60
        return s == 0 ? "\(m) min" : "\(m) min \(s) s"
    }
}
