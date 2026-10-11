import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Opt-out switch for the live dashboard block on Today (default ON).
enum LiveDashboardPrefs {
    static let enabledKey = "noop.liveDashboard"
}

/// The live dashboard block that sits under Today's Charge / Effort / Rest rings: today's heart rate,
/// today's stress + Effort on one chart, and last night's sleep stages. Every chart covers the whole day
/// and keeps moving while the strap streams.
///
/// Display-only. Heart rate is the banked history since local midnight merged with the samples the Live
/// Trace recorder captured this session; stress and Effort are the Live Trace recorder's day lines
/// (`LiveTraceStore`); sleep is the same `StagesCard` the hosted Sleep card renders.
struct LiveDashboardCards: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState
    @ObservedObject private var trace = LiveTraceStore.shared
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    @State private var bankedHR: [HRSample] = []
    @State private var sleepModel: SleepModel?

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heartRateCard
            stressStrainCard
            if let sleepModel {
                StrandCard { StagesCard(model: sleepModel) }
            }
        }
        // Banked history is re-read once a minute (and on every repository refresh); the live tail
        // arrives through `LiveTraceStore` every second in between.
        .task(id: repo.refreshSeq) {
            await loadSleep()
            while !Task.isCancelled {
                await loadBankedHR()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    // MARK: Heart rate

    private var heartRateCard: some View {
        let points = Self.minuteMeans(merge(bankedHR, trace.today.hrSamples))
        let start = Calendar.current.startOfDay(for: Date())
        return StrandCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "heart.fill").foregroundStyle(StrandPalette.liquidHeart)
                    Text("HEART RATE").strandOverline()
                    Spacer()
                    Text(live.connected ? (live.heartRate.map { "\($0)" } ?? "—") : (points.last.map { "\(Int($0.value))" } ?? "—"))
                        .font(StrandFont.number(26))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("bpm").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Chart(points) { p in
                    LineMark(x: .value("Time", p.ts), y: .value("bpm", p.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(StrandPalette.liquidHeart)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                }
                .chartXScale(domain: start...max(Date(), start.addingTimeInterval(3600)))
                .chartYScale(domain: hrDomain(points))
                .chartXAxis { timeAxis }
                .chartYAxis { valueAxis }
                .frame(height: 150)
                if points.isEmpty {
                    Text("No heart rate yet today. Connect your strap to start the line.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    // MARK: Stress & Strain

    private enum Series: String { case stress = "Stress", effort = "Effort" }

    private struct Line: Identifiable {
        let series: Series
        let ts: Date
        let value: Double
        var id: String { "\(series.rawValue)-\(ts.timeIntervalSince1970)" }
    }

    private var stressStrainCard: some View {
        let day = trace.today
        let start = Calendar.current.startOfDay(for: Date())
        let effortTop = max(10, (day.effort.max() ?? 0) * 1.2)
        // Effort is drawn on the stress axis (0-3), scaled so its own day peak sits below the top.
        let lines = day.stressPoints.map { Line(series: .stress, ts: $0.ts, value: $0.value) }
            + day.effortPoints.map { Line(series: .effort, ts: $0.ts, value: $0.value / effortTop * 3) }
        let stressNow = trace.stress.last?.value ?? day.stress.last
        let effortNow = trace.effort.last?.value ?? day.effort.last
        let updated = day.stressTs.last.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return StrandCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("STRESS & STRAIN").strandOverline()
                    Spacer()
                    if let updated {
                        Text("updated \(updated.formatted(date: .omitted, time: .shortened))")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    readout(label: stressNow.map(Self.stressBand) ?? String(localized: "stress"),
                            value: stressNow.map(StressTrace.formatLevel), tint: StrandPalette.textPrimary)
                    readout(label: String(localized: "effort"),
                            value: effortNow.map { UnitFormatter.effortDisplay($0, scale: effortScale) },
                            tint: StrandPalette.strainColor(effortNow ?? 0))
                    Spacer()
                }
                Chart(lines) { l in
                    LineMark(x: .value("Time", l.ts), y: .value("Value", l.value),
                             series: .value("Series", l.series.rawValue))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Series", l.series.rawValue))
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                }
                .chartForegroundStyleScale([
                    Series.stress.rawValue: StrandPalette.textPrimary,
                    Series.effort.rawValue: StrandPalette.strainColor(effortNow ?? 0),
                ])
                .chartLegend(.hidden)
                .chartXScale(domain: start...max(Date(), start.addingTimeInterval(3600)))
                .chartYScale(domain: 0...3)
                .chartXAxis { timeAxis }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [0, 1, 2, 3]) { _ in
                        AxisGridLine().foregroundStyle(StrandPalette.hairline)
                        AxisValueLabel().font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .frame(height: 150)
                Text(lines.isEmpty
                     ? String(localized: "Fills in while your strap streams live to NOOP.")
                     : String(localized: "Stress 0-3 · Effort scaled to today's peak. Only time your strap streamed live is drawn."))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func readout(label: String, value: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—").font(StrandFont.number(24)).foregroundStyle(tint)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// Band words on the shared 0-3 scale; HIGH starts at `StressTrace.highBandFloor`.
    private static func stressBand(_ v: Double) -> String {
        if v >= StressTrace.highBandFloor { return String(localized: "high") }
        if v >= 1 { return String(localized: "medium") }
        return String(localized: "low")
    }

    // MARK: Shared chart bits

    private var timeAxis: some AxisContent {
        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
            AxisGridLine().foregroundStyle(StrandPalette.hairline)
            AxisValueLabel(format: .dateTime.hour())
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var valueAxis: some AxisContent {
        AxisMarks(position: .trailing) { _ in
            AxisGridLine().foregroundStyle(StrandPalette.hairline)
            AxisValueLabel().font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func hrDomain(_ pts: [LiveTraceStore.Point]) -> ClosedRange<Double> {
        let lo = (pts.map(\.value).min() ?? 50) - 5
        let hi = (pts.map(\.value).max() ?? 120) + 5
        return max(30, lo)...max(lo + 20, hi)
    }

    // MARK: Data

    private func merge(_ a: [HRSample], _ b: [HRSample]) -> [HRSample] {
        var byTs: [Int: Int] = [:]
        for s in a where s.bpm > 0 { byTs[s.ts] = s.bpm }
        for s in b where s.bpm > 0 { byTs[s.ts] = s.bpm }
        return byTs.map { HRSample(ts: $0.key, bpm: $0.value) }.sorted { $0.ts < $1.ts }
    }

    /// One point per minute (the mean), so a full day stays a few hundred marks instead of ~86k.
    private static func minuteMeans(_ samples: [HRSample]) -> [LiveTraceStore.Point] {
        var sums: [Int: (Int, Int)] = [:]
        for s in samples {
            let m = s.ts / 60
            let cur = sums[m] ?? (0, 0)
            sums[m] = (cur.0 + s.bpm, cur.1 + 1)
        }
        return sums.keys.sorted().map { m in
            let (sum, n) = sums[m]!
            return LiveTraceStore.Point(ts: Date(timeIntervalSince1970: TimeInterval(m * 60)),
                                        value: Double(sum) / Double(n))
        }
    }

    private func loadBankedHR() async {
        let from = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        bankedHR = await repo.hrSamples(from: from, to: Int(Date().timeIntervalSince1970), limit: 90_000)
    }

    private func loadSleep() async {
        let sessions = await repo.allSleepSessions()
        let habitual = await repo.habitualMidsleepSec()
        let motion = await repo.sessionMotions(sessions: sessions)
        sleepModel = SleepModel.build(SleepModelInputs(
            days: repo.days,
            sleeps: repo.sleeps,
            allSessions: sessions,
            importedSleep: repo.importedSleep,
            habitualMidsleepSec: habitual,
            motionByStart: motion))
    }
}
