import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// The Effort ring's detail page: the score, what built it today (time in heart-rate zones, steps,
/// calories) against your recent days, and the last seven days.
///
/// Read-only. Zone time is `HRZones.timeInZone` over each day's banked heart rate with the profile's own
/// zone set (the same model the workout zone split uses); steps and calories are the daily rows; the big
/// ring shows the Effort the Today ring drew so the two never disagree.
struct EffortDetailView: View {
    let heroEffort: Double?
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    /// Zone minutes per day key: [z1, z2, z3, z4, z5].
    @State private var zonesByDay: [String: [Double]] = [:]

    private var scale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    private var todayKey: String { Repository.localDayKey(Date()) }
    private var todayRow: DailyMetric? { repo.days.last { $0.day == todayKey } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                scoreRing
                contributors
                sectionTitle("Weekly trends", sub: "last 7 days")
                effortChart
                zonesChart(title: "HR ZONES 1-3", range: 0..<3,
                           colors: [StrandPalette.zone1, StrandPalette.zone2, StrandPalette.zone3])
                zonesChart(title: "HR ZONES 4-5", range: 3..<5,
                           colors: [StrandPalette.zone4, StrandPalette.zone5])
                barChart("STEPS", week { $0.steps.map(Double.init) }, format: { Self.thousands($0) },
                         color: StrandPalette.chargeColor)
                dotChart("CALORIES (EST.)", week { $0.activeKcalEst }, format: { Self.thousands($0) },
                         color: StrandPalette.metricAmber)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 32)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle("Effort")
        .task(id: repo.refreshSeq) { await loadZones() }
    }

    // MARK: Score

    private var effort: Double? { heroEffort ?? todayRow?.strain }
    private var effortMax: Double { scale == .whoop ? 21 : 100 }

    private var scoreRing: some View {
        let shown = effort.map { UnitFormatter.effortValue($0, scale: scale) }
        return ZStack {
            Circle().stroke(StrandPalette.surfaceInset, lineWidth: 12)
            Circle()
                .trim(from: 0, to: CGFloat(min(max((shown ?? 0) / effortMax, 0), 1)))
                .stroke(StrandPalette.effortColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 6) {
                Text(effort.map { UnitFormatter.effortDisplay($0, scale: scale) } ?? "—")
                    .font(StrandFont.number(52, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("EFFORT").strandOverline()
            }
        }
        .frame(width: 190, height: 190)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    // MARK: Contributors (today vs the previous days on record)

    private var contributors: some View {
        let todayZones = zonesByDay[todayKey]
        let prior = zonesByDay.filter { $0.key != todayKey }.values
        func typical(_ f: ([Double]) -> Double) -> Double? {
            prior.isEmpty ? nil : prior.map(f).reduce(0, +) / Double(prior.count)
        }
        let low: ([Double]) -> Double = { $0.prefix(3).reduce(0, +) }
        let high: ([Double]) -> Double = { $0.suffix(2).reduce(0, +) }
        let pastDays = repo.days.filter { $0.day < todayKey }.suffix(30)
        func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
        return StrandCard {
            VStack(spacing: 0) {
                row("Heart rate zones 1-3", todayZones.map(low).map(Self.hm), typical(low).map(Self.hm),
                    up: todayZones.map(low), vs: typical(low))
                Divider().overlay(StrandPalette.hairline)
                row("Heart rate zones 4-5", todayZones.map(high).map(Self.hm), typical(high).map(Self.hm),
                    up: todayZones.map(high), vs: typical(high))
                Divider().overlay(StrandPalette.hairline)
                let stepsTyp = mean(pastDays.compactMap { $0.steps.map(Double.init) })
                row("Steps", todayRow?.steps.map { Self.thousands(Double($0)) }, stepsTyp.map(Self.thousands),
                    up: todayRow?.steps.map(Double.init), vs: stepsTyp)
                Divider().overlay(StrandPalette.hairline)
                let kcalTyp = mean(pastDays.compactMap(\.activeKcalEst))
                row("Calories (est.)", todayRow?.activeKcalEst.map(Self.thousands), kcalTyp.map(Self.thousands),
                    up: todayRow?.activeKcalEst, vs: kcalTyp)
                HStack {
                    Text("today vs your previous days (small grey figure)")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                }
                .padding(.top, 10)
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String?, _ typical: String?,
                     up: Double?, vs: Double?) -> some View {
        HStack(alignment: .center) {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    Text(value ?? "—").font(StrandFont.number(20)).foregroundStyle(StrandPalette.textPrimary)
                    if let up, let vs, vs > 0 {
                        Image(systemName: up >= vs ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                            .font(.caption2)
                            .foregroundStyle(up >= vs ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                    }
                }
                if let typical {
                    Text(typical).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .padding(.vertical, 12)
    }

    // MARK: Weekly trends

    private struct DayValue: Identifiable {
        let day: String
        let label: String
        let value: Double?
        var id: String { day }
    }

    private struct DayKey {
        let key: String
        let label: String
    }

    private var weekKeys: [DayKey] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return (0..<7).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .day, value: -back, to: Date()) else { return nil }
            return DayKey(key: Repository.localDayKey(d), label: f.string(from: d).lowercased())
        }
    }

    private func week(_ value: (DailyMetric) -> Double?) -> [DayValue] {
        let byDay = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        return weekKeys.map { k in DayValue(day: k.key, label: k.label, value: byDay[k.key].flatMap(value)) }
    }

    private var effortChart: some View {
        dotChart("EFFORT", week { d in d.strain.map { UnitFormatter.effortValue($0, scale: scale) } },
                 format: { scale == .whoop ? String(format: "%.1f", $0) : "\(Int($0.rounded()))" },
                 color: StrandPalette.effortColor)
    }

    private struct ZoneBar: Identifiable {
        let label: String
        let zone: String
        let minutes: Double
        var id: String { label + zone }
    }

    private func zonesChart(title: String, range: Range<Int>, colors: [Color]) -> some View {
        let keys = weekKeys
        let bars: [ZoneBar] = keys.flatMap { k -> [ZoneBar] in
            guard let z = zonesByDay[k.key] else { return [] }
            return range.map { ZoneBar(label: k.label, zone: "Zone \($0 + 1)", minutes: z[$0]) }
        }
        let totals = Dictionary(grouping: bars, by: \.label).mapValues { $0.reduce(0) { $0 + $1.minutes } }
        let names = range.map { "Zone \($0 + 1)" }
        return StrandCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).strandOverline()
                    Spacer()
                    ForEach(names.indices, id: \.self) { i in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(colors[i]).frame(width: 8, height: 8)
                            Text(names[i].lowercased()).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                }
                Chart {
                    ForEach(bars) { b in
                        BarMark(x: .value("Day", b.label), y: .value("Minutes", b.minutes), width: .ratio(0.4))
                            .foregroundStyle(by: .value("Zone", b.zone))
                    }
                    ForEach(keys.filter { totals[$0.label] != nil }, id: \.key) { k in
                        PointMark(x: .value("Day", k.label), y: .value("Minutes", totals[k.label] ?? 0))
                            .opacity(0)
                            .annotation(position: .top, spacing: 2) {
                                Text(Self.hm(totals[k.label] ?? 0)).font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                    }
                }
                .chartForegroundStyleScale(domain: names, range: colors)
                .chartLegend(.hidden)
                .chartXScale(domain: keys.map(\.label))
                .chartYAxis(.hidden)
                .chartXAxis { dayAxis }
                .frame(height: 130)
                if zonesByDay.isEmpty {
                    Text("Reading heart rate…").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private func dotChart(_ title: String, _ data: [DayValue], format: @escaping (Double) -> String,
                          color: Color) -> some View {
        let present = data.filter { $0.value != nil }
        let vals = present.compactMap(\.value)
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        let pad = Swift.max((hi - lo) * 0.35, hi * 0.08, 1)
        return StrandCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).strandOverline()
                Chart {
                    ForEach(present) { p in
                        LineMark(x: .value("Day", p.label), y: .value(title, p.value ?? 0))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("Day", p.label), y: .value(title, p.value ?? 0))
                            .symbol {
                                Circle().strokeBorder(color, lineWidth: 2.5)
                                    .background(Circle().fill(StrandPalette.surfaceRaised))
                                    .frame(width: 11, height: 11)
                            }
                            .annotation(position: .top, spacing: 4) {
                                Text(format(p.value ?? 0)).font(StrandFont.caption).foregroundStyle(color)
                            }
                    }
                }
                .chartXScale(domain: data.map(\.label))
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartYAxis(.hidden)
                .chartXAxis { dayAxis }
                .frame(height: 130)
            }
        }
    }

    private func barChart(_ title: String, _ data: [DayValue], format: @escaping (Double) -> String,
                          color: Color) -> some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).strandOverline()
                Chart {
                    ForEach(data.filter { $0.value != nil }) { p in
                        BarMark(x: .value("Day", p.label), y: .value(title, p.value ?? 0), width: .ratio(0.4))
                            .foregroundStyle(color.opacity(p.day == data.last?.day ? 1 : 0.6))
                            .cornerRadius(2)
                            .annotation(position: .top, spacing: 4) {
                                Text(format(p.value ?? 0)).font(StrandFont.caption).foregroundStyle(color)
                            }
                    }
                }
                .chartXScale(domain: data.map(\.label))
                .chartYAxis(.hidden)
                .chartXAxis { dayAxis }
                .frame(height: 130)
            }
        }
    }

    private var dayAxis: some AxisContent {
        AxisMarks { _ in
            AxisValueLabel().font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: Bits

    private func sectionTitle(_ title: LocalizedStringKey, sub: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(sub).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.top, 14)
        .padding(.horizontal, 2)
    }

    static func hm(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }

    static func thousands(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0)))
    }

    /// Time in zone for each of the last seven days, from that day's banked heart rate.
    private func loadZones() async {
        let zoneSet = profile.hrZoneSet
        let cal = Calendar.current
        var result: [String: [Double]] = [:]
        for back in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let start = cal.startOfDay(for: day)
            let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
            let samples = await repo.hrSamples(from: Int(start.timeIntervalSince1970),
                                               to: Int(min(end, Date()).timeIntervalSince1970),
                                               limit: 100_000)
            guard !samples.isEmpty else { continue }
            let tiz = HRZones.timeInZone(samples, zoneSet: zoneSet)
            result[Repository.localDayKey(day)] = tiz.seconds.map { $0 / 60 }
        }
        zonesByDay = result
    }
}
