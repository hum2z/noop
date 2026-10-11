import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The Rest ring's detail page: the score, what fed it, last night in detail, and the last seven nights.
///
/// Read-only over existing figures. Contributors come from `SleepModel` (the Sleep tab's own builder),
/// the weekly lines recompute the same per-day formulas over `Repository.days`, and the big ring shows
/// the score the Today ring drew so the two never disagree. The poor / sufficient / optimal bands are a
/// display convention for reading the contributors at a glance, not part of any score.
struct RestDetailView: View {
    let heroScore: Double?
    @EnvironmentObject private var repo: Repository
    @State private var model: SleepModel?
    @State private var nightHR: [HRBucket] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                scoreRing
                if let model {
                    contributors(model)
                    sectionTitle("Last night's sleep", sub: "vs your typical night")
                    lastNight(model)
                } else {
                    Text("No scored night yet. Sleep with the strap on and let NOOP sync in the morning.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.horizontal, 16)
                }
                sectionTitle("Weekly trends", sub: "last 7 nights")
                trends
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 32)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle("Rest")
        .task(id: repo.refreshSeq) { await load() }
    }

    // MARK: Score

    private var score: Double? { heroScore ?? model?.performance.latest }

    private var scoreRing: some View {
        ZStack {
            Circle().stroke(StrandPalette.surfaceInset, lineWidth: 12)
            Circle()
                .trim(from: 0, to: CGFloat(min(max((score ?? 0) / 100, 0), 1)))
                .stroke(StrandPalette.restColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 6) {
                Text(score.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(StrandFont.number(52, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("REST").strandOverline()
            }
        }
        .frame(width: 190, height: 190)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    // MARK: Contributors

    private enum Band: Int { case poor, sufficient, optimal }

    private func band(_ v: Double?, optimal: Double, sufficient: Double) -> Band? {
        guard let v else { return nil }
        return v >= optimal ? .optimal : v >= sufficient ? .sufficient : .poor
    }

    private func contributors(_ m: SleepModel) -> some View {
        StrandCard {
            VStack(spacing: 0) {
                contributorRow("Hours vs needed", m.hoursVsNeeded.latest, band(m.hoursVsNeeded.latest, optimal: 85, sufficient: 70))
                Divider().overlay(StrandPalette.hairline)
                contributorRow("Consistency", m.consistency.latest, band(m.consistency.latest, optimal: 70, sufficient: 50))
                Divider().overlay(StrandPalette.hairline)
                contributorRow("Efficiency", m.efficiency.latest, band(m.efficiency.latest, optimal: 90, sufficient: 80))
                Divider().overlay(StrandPalette.hairline)
                contributorRow("Restorative", m.restorative.latest, band(m.restorative.latest, optimal: 40, sufficient: 30))
                HStack(spacing: 14) {
                    legend("poor", StrandPalette.statusWarning)
                    legend("sufficient", StrandPalette.textTertiary)
                    legend("optimal", StrandPalette.statusPositive)
                    Spacer()
                }
                .padding(.top, 10)
            }
        }
    }

    private func contributorRow(_ label: LocalizedStringKey, _ value: Double?, _ b: Band?) -> some View {
        HStack {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(segmentColor(i, b))
                        .frame(width: 22, height: 4)
                }
            }
            Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(StrandFont.number(18))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }

    private func segmentColor(_ i: Int, _ b: Band?) -> Color {
        guard let b, b.rawValue == i else { return StrandPalette.surfaceInset }
        switch b {
        case .poor:       return StrandPalette.statusWarning
        case .sufficient: return StrandPalette.textTertiary
        case .optimal:    return StrandPalette.statusPositive
        }
    }

    private func legend(_ text: LocalizedStringKey, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(c).frame(width: 10, height: 3)
            Text(text).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: Last night

    private func lastNight(_ m: SleepModel) -> some View {
        let s = m.night.stages
        return StrandCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("HOURS OF SLEEP").strandOverline()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.hm(s.asleep)).font(StrandFont.number(30, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let t = m.typicalTotalMin {
                        Image(systemName: s.asleep >= t ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                            .font(.caption)
                            .foregroundStyle(s.asleep >= t ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                    }
                }
                if let t = m.typicalTotalMin {
                    Text("typical \(Self.hm(t))").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                if !nightHR.isEmpty {
                    Chart(nightHR, id: \.ts) { b in
                        LineMark(x: .value("Time", Date(timeIntervalSince1970: TimeInterval(b.ts))),
                                 y: .value("bpm", b.bpm))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(StrandPalette.sleepLight)
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                            AxisValueLabel(format: .dateTime.hour().minute())
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine().foregroundStyle(StrandPalette.hairline)
                            AxisValueLabel().font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .frame(height: 120)
                    Text("heart rate during sleep").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                HStack {
                    Text("STAGES · ┆ typical").strandOverline()
                    Spacer()
                    Text(Self.hm(s.total)).font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
                }
                .padding(.top, 6)
                stageRow("Awake", s.awake, s.total, nil, StrandPalette.sleepAwake)
                stageRow("Light", s.light, s.total, m.typicalLightMin, StrandPalette.sleepLight)
                stageRow("Deep", s.deep, s.total, m.typicalDeepMin, StrandPalette.sleepDeep)
                stageRow("REM", s.rem, s.total, m.typicalRemMin, StrandPalette.sleepREM)
            }
        }
    }

    private func stageRow(_ name: LocalizedStringKey, _ min: Double, _ total: Double, _ typical: Double?,
                          _ color: Color) -> some View {
        let frac = total > 0 ? min / total : 0
        let typFrac = (typical ?? 0) / Swift.max(total, 1)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(name).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text("\(Int((frac * 100).rounded()))%").font(StrandFont.subhead).foregroundStyle(color)
                Spacer()
                Text(Self.hm(min)).font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(StrandPalette.surfaceInset)
                    RoundedRectangle(cornerRadius: 3).fill(color)
                        .frame(width: geo.size.width * CGFloat(Swift.min(frac * 2, 1)))
                    if typical != nil {
                        Rectangle().fill(StrandPalette.textTertiary)
                            .frame(width: 2, height: 16)
                            .offset(x: geo.size.width * CGFloat(Swift.min(typFrac * 2, 1)) - 1)
                    }
                }
            }
            .frame(height: 10)
        }
        .padding(.top, 4)
    }

    // MARK: Weekly trends

    private struct DayValue: Identifiable {
        let day: String
        let label: String
        let value: Double?
        var id: String { day }
    }

    /// The last seven calendar days, oldest first, each with its weekday label.
    private var weekKeys: [(key: String, label: String)] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return (0..<7).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .day, value: -back, to: Date()) else { return nil }
            return (Repository.localDayKey(d), f.string(from: d).lowercased())
        }
    }

    private func week(_ value: (DailyMetric) -> Double?) -> [DayValue] {
        let byDay = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        return weekKeys.map { k in DayValue(day: k.key, label: k.label, value: byDay[k.key].flatMap(value)) }
    }

    @ViewBuilder private var trends: some View {
        let imported = repo.importedSleep
        dotChart("REST", week { d in imported[d.day]?.performancePct ?? AnalyticsEngine.Rest.composite(daily: d) },
                 format: { "\(Int($0.rounded()))%" }, color: StrandPalette.restColor)
        dotChart("HOURS OF SLEEP", week { d in d.totalSleepMin.map { $0 / 60 } },
                 format: { Self.hm($0 * 60) }, color: StrandPalette.sleepLight)
        debtChart
        dotChart("EFFICIENCY", week { d in d.efficiency.map { $0 <= 1 ? $0 * 100 : $0 } },
                 format: { "\(Int($0.rounded()))%" }, color: StrandPalette.statusPositive)
    }

    private func dotChart(_ title: String, _ data: [DayValue], format: @escaping (Double) -> String,
                          color: Color) -> some View {
        let present = data.filter { $0.value != nil }
        let vals = present.compactMap(\.value)
        let lo = (vals.min() ?? 0), hi = (vals.max() ?? 1)
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
                            .symbol { Circle().strokeBorder(color, lineWidth: 2.5).background(Circle().fill(StrandPalette.surfaceRaised)).frame(width: 11, height: 11) }
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

    private var debtChart: some View {
        let need = SleepModel.debtNeedMin(days: repo.days)
        let series = SleepDebt.debtSeries(
            series: repo.days.map { (day: $0.day, totalSleepMin: $0.totalSleepMin) },
            needHours: need / 60,
            importedDebtMin: repo.importedSleep.compactMapValues(\.debtMin))
        let byDay = Dictionary(series.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        let data = weekKeys.map { DayValue(day: $0.key, label: $0.label, value: byDay[$0.key]) }
        return StrandCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("SLEEP DEBT").strandOverline()
                Chart {
                    ForEach(data.filter { $0.value != nil }) { p in
                        BarMark(x: .value("Day", p.label), y: .value("Debt", p.value ?? 0), width: .ratio(0.4))
                            .foregroundStyle(StrandPalette.sleepLight.opacity(p.day == data.last?.day ? 1 : 0.55))
                            .cornerRadius(2)
                            .annotation(position: .top, spacing: 4) {
                                Text(Self.hm(p.value ?? 0)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
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

    /// Minutes as h:mm.
    static func hm(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }

    private func load() async {
        let sessions = await repo.allSleepSessions()
        let habitual = await repo.habitualMidsleepSec()
        let motion = await repo.sessionMotions(sessions: sessions)
        model = SleepModel.build(SleepModelInputs(
            days: repo.days,
            sleeps: repo.sleeps,
            allSessions: sessions,
            importedSleep: repo.importedSleep,
            habitualMidsleepSec: habitual,
            motionByStart: motion))
        if let night = model?.night {
            nightHR = await repo.hrBuckets(from: night.session.startTs, to: night.session.endTs, bucketSeconds: 60)
        }
    }
}
