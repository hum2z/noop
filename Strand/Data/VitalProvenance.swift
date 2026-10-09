import Foundation
import WhoopStore

/// Names where a Today vital tile's number came from — the strap (NOOP computed), a WHOOP import, or
/// Apple Health — and, when it is carried from an earlier day, which day.
///
/// The tiles resolve their value through a `displayDay ?? vitalsDay ?? …` carry chain over the MERGED
/// daily rows, which hides the source. This walks the same candidate days in the same order against the
/// source-tagged `vitalRows`, using the same per-metric precedence the Vital Signs card uses
/// (`DailyMetricSource.vitalPrecedence`), so the label names the row that actually supplied the value.
extension Repository {
    func vitalProvenance(key: String, candidateDays: [String?],
                         _ value: (DailyMetric) -> Double?) -> String? {
        let precedence = DailyMetricSource.vitalPrecedence(for: key)
        for case let day? in candidateDays {
            let rows = vitalMetricRows.filter { $0.metric.day == day && value($0.metric) != nil }
            guard let row = precedence.lazy.compactMap({ src in rows.first { $0.source == src } }).first
            else { continue }
            guard let name = Self.provenanceName(row.source) else { return nil }
            let today = Repository.localDayKey(Date())
            return day == today ? name : "\(name) · \(BodyVitalReading.dayLabel(day))"
        }
        return nil
    }

    private static func provenanceName(_ source: DailyMetricSource) -> String? {
        switch source {
        case .whoopImport:  return String(localized: "WHOOP import")
        case .noopComputed: return String(localized: "from strap")
        case .appleHealth:  return String(localized: "Apple Health")
        case .localCache:   return nil
        }
    }
}
