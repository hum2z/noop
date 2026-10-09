import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopProtocol

/// Second-by-second live stress + Effort lines, fed by the strap's live heart rate and R-R.
///
/// Display-only instrumentation: nothing here is stored or feeds a score. Stress is the same 0-3 squash
/// the daytime timeline uses (`DaytimeStress.rawScore` / `squash`), scored over a rolling 30 s HR mean
/// and the last ~40 live R-R intervals against today's resting HR and HRV. Effort is
/// `StrainScorer.strain` over every live HR sample captured since collection started, so it climbs
/// the same way a manual workout's live Effort does.
@MainActor
final class LiveTraceStore: ObservableObject {
    static let shared = LiveTraceStore()

    struct Point: Identifiable {
        let ts: Date
        let value: Double
        var id: Date { ts }
    }

    /// How much of each line the card shows.
    static let windowSeconds: TimeInterval = 10 * 60
    /// Cap on banked live HR for the Effort integral (~6 h at 1 Hz).
    private static let maxSamples = 6 * 3600

    @Published private(set) var stress: [Point] = []
    @Published private(set) var effort: [Point] = []
    @Published private(set) var startedAt: Date?

    private weak var live: LiveState?
    private var samples: [HRSample] = []
    private var ticker: Task<Void, Never>?
    private var restingHR = StrainScorer.defaultRestingHR
    private var baselineRMSSD = 45.0
    private var maxHR = 190.0
    private var sex = "male"

    /// Starts the 1 Hz sampler (idempotent) and refreshes the personal baselines.
    func attach(_ live: LiveState, restingHR: Int?, avgHrv: Double?, maxHR: Int, sex: String) {
        self.live = live
        if let r = restingHR, r > 0 { self.restingHR = Double(r) }
        if let h = avgHrv, h > 0 { baselineRMSSD = h }
        if maxHR > 0 { self.maxHR = Double(maxHR) }
        self.sex = sex
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let live, live.connected, let hr = live.heartRate, hr > 0 else { return }
        let now = Date()
        if startedAt == nil { startedAt = now }
        samples.append(HRSample(ts: Int(now.timeIntervalSince1970), bpm: hr))
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }

        // Awake, seated HR sits ~10 bpm over resting, so that is the "calm" centre of the curve.
        let recent = samples.suffix(30).map { Double($0.bpm) }
        let meanHR = recent.reduce(0, +) / Double(recent.count)
        let rmssd = HRVAnalyzer.rmssdRaw(HRVAnalyzer.cleanRR(live.rrRecent.suffix(40).map { Double($0) }))
        let raw = DaytimeStress.rawScore(hr: meanHR, meanHR: restingHR + 10, sdHR: 12,
                                         rmssd: rmssd, meanRMSSD: baselineRMSSD, sdRMSSD: 15)
        stress.append(Point(ts: now, value: DaytimeStress.squash(raw)))

        if let e = StrainScorer.strain(samples, maxHR: maxHR, restingHR: restingHR,
                                       method: PuffinExperiment.effortMethod, sex: sex) {
            effort.append(Point(ts: now, value: e))
        }

        let cutoff = now.addingTimeInterval(-Self.windowSeconds)
        stress.removeAll { $0.ts < cutoff }
        effort.removeAll { $0.ts < cutoff }
    }
}

/// The card on the Live screen: two live line charts (stress 0-3, Effort) that move every second.
struct LiveTraceCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @ObservedObject private var store = LiveTraceStore.shared
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    var body: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("LIVE TRACE").strandOverline()
                    Spacer()
                    Circle()
                        .fill(live.connected ? StrandPalette.statusPositive : StrandPalette.textTertiary)
                        .frame(width: 7, height: 7)
                    Text(live.connected ? "streaming" : "not connected")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                trace(title: "Stress", value: store.stress.last.map { StressTrace.formatLevel($0.value) },
                      points: store.stress, domain: 0...3, tint: StrandPalette.statusWarning)
                trace(title: "Effort",
                      value: store.effort.last.map {
                          UnitFormatter.effortDisplay($0.value, scale: UnitPrefs.resolveEffortScale(effortScaleRaw))
                      },
                      points: store.effort, domain: 0...max(10, (store.effort.map(\.value).max() ?? 0) * 1.2),
                      tint: StrandPalette.strainColor(store.effort.last?.value ?? 0))
                Text(footnote)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .onAppear {
            LiveTraceStore.shared.attach(live, restingHR: model.repo.today?.restingHr,
                                         avgHrv: model.repo.today?.avgHrv,
                                         maxHR: model.profile.hrMax, sex: model.profile.sex)
        }
    }

    private var footnote: String {
        guard let start = store.startedAt else {
            return String(localized: "Connect your strap — the lines start moving with your live heart rate.")
        }
        return String(localized: "Live estimate, updated every second. Effort counts from \(start.formatted(date: .omitted, time: .shortened)).")
    }

    private func trace(title: LocalizedStringKey, value: String?, points: [LiveTraceStore.Point],
                       domain: ClosedRange<Double>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text(value ?? "—").font(StrandFont.number(22)).foregroundStyle(StrandPalette.textPrimary)
            }
            Chart(points) { p in
                LineMark(x: .value("Time", p.ts), y: .value(title, p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .chartYScale(domain: domain)
            .chartXScale(domain: Date().addingTimeInterval(-LiveTraceStore.windowSeconds)...Date())
            .chartXAxis {
                AxisMarks(values: .stride(by: .minute, count: 2)) { _ in
                    AxisGridLine().foregroundStyle(StrandPalette.hairline)
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in
                    AxisGridLine().foregroundStyle(StrandPalette.hairline)
                    AxisValueLabel().font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(height: 110)
        }
    }
}
