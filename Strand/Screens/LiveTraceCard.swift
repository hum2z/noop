import SwiftUI
import Charts
import Combine
import StrandDesign
import StrandAnalytics
import WhoopProtocol

/// Second-by-second live stress + Effort, recorded to on-device storage one file per day so past days
/// can be scrolled back to.
///
/// Display-only instrumentation: nothing here feeds a score. Stress is the same 0-3 squash the daytime
/// timeline uses (`DaytimeStress.rawScore` / `squash`), scored over a rolling 30 s HR mean and the last
/// ~40 live R-R intervals against today's resting HR and HRV. Effort is `StrainScorer.strain` over every
/// live HR sample captured that day, so it climbs the way a manual workout's live Effort does.
///
/// Samples are taken on each live heart-rate push (about 1 Hz), so recording continues whenever the
/// strap is streaming — including while NOOP runs in the background — and resets at local midnight.
@MainActor
final class LiveTraceStore: ObservableObject {
    static let shared = LiveTraceStore()

    struct Point: Identifiable, Equatable {
        let ts: Date
        let value: Double
        var id: Date { ts }
    }

    /// One recorded day, as stored on disk. Parallel arrays keep the file compact.
    struct Day: Codable, Equatable {
        var day: String
        var hrTs: [Int] = []
        var hrBpm: [Int] = []
        var stressTs: [Int] = []
        var stress: [Double] = []
        var effortTs: [Int] = []
        var effort: [Double] = []

        var stressPoints: [Point] { zip(stressTs, stress).map { Point(ts: Date(timeIntervalSince1970: TimeInterval($0)), value: $1) } }
        var effortPoints: [Point] { zip(effortTs, effort).map { Point(ts: Date(timeIntervalSince1970: TimeInterval($0)), value: $1) } }
        var hrSamples: [HRSample] { zip(hrTs, hrBpm).map { HRSample(ts: $0, bpm: $1) } }
        var recordedMinutes: Int { hrTs.count / 60 }
        var avgStress: Double? { stress.isEmpty ? nil : stress.reduce(0, +) / Double(stress.count) }
        var peakStress: Double? { stress.max() }
        var finalEffort: Double? { effort.last }
    }

    /// How much of each line the live view shows.
    static let windowSeconds: TimeInterval = 10 * 60
    /// Day lines keep one point per this many seconds (the live view keeps every second).
    private static let dayStepSeconds = 5
    /// Rewrite today's file at most this often while recording.
    private static let saveEverySeconds: TimeInterval = 120
    /// Days older than this are deleted.
    private static let keepDays = 120

    @Published private(set) var stress: [Point] = []
    @Published private(set) var effort: [Point] = []
    @Published private(set) var today: Day
    /// Day keys with a stored recording, newest first (today included once it has data).
    @Published private(set) var recordedDays: [String] = []

    private weak var live: LiveState?
    private var hrSub: AnyCancellable?
    private var lastSampleTs = 0
    private var lastSave = Date.distantPast
    private var restingHR = StrainScorer.defaultRestingHR
    private var baselineRMSSD = 45.0
    private var maxHR = 190.0
    private var sex = "male"

    private init() {
        let key = Self.dayKey(Date())
        today = Self.load(key) ?? Day(day: key)
        recordedDays = Self.storedDayKeys()
        Self.prune()
    }

    /// Starts recording (idempotent) and refreshes the personal baselines.
    func attach(_ live: LiveState, restingHR: Int?, avgHrv: Double?, maxHR: Int, sex: String) {
        if let r = restingHR, r > 0 { self.restingHR = Double(r) }
        if let h = avgHrv, h > 0 { baselineRMSSD = h }
        if maxHR > 0 { self.maxHR = Double(maxHR) }
        self.sex = sex
        guard hrSub == nil else { return }
        self.live = live
        hrSub = live.$heartRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    /// The stored recording for `key`, or nil when that day has none.
    func day(_ key: String) -> Day? {
        key == today.day ? today : Self.load(key)
    }

    /// Writes today's recording now (e.g. when the app leaves the foreground).
    func flush() {
        guard !today.hrTs.isEmpty else { return }
        Self.save(today)
        lastSave = Date()
    }

    private func tick() {
        guard let live, live.connected, let hr = live.heartRate, hr > 0 else { return }
        let now = Date()
        let ts = Int(now.timeIntervalSince1970)
        guard ts != lastSampleTs else { return }
        lastSampleTs = ts

        let key = Self.dayKey(now)
        if key != today.day {
            flush()
            today = Day(day: key)
            stress.removeAll()
            effort.removeAll()
        }

        today.hrTs.append(ts)
        today.hrBpm.append(hr)
        let samples = today.hrSamples

        // Awake, seated HR sits ~10 bpm over resting, so that is the "calm" centre of the curve.
        let recent = today.hrBpm.suffix(30).map { Double($0) }
        let meanHR = recent.reduce(0, +) / Double(recent.count)
        let rmssd = HRVAnalyzer.rmssdRaw(HRVAnalyzer.cleanRR(live.rrRecent.suffix(40).map { Double($0) }))
        let raw = DaytimeStress.rawScore(hr: meanHR, meanHR: restingHR + 10, sdHR: 12,
                                         rmssd: rmssd, meanRMSSD: baselineRMSSD, sdRMSSD: 15)
        let s = DaytimeStress.squash(raw)
        stress.append(Point(ts: now, value: s))
        let e = StrainScorer.strain(samples, maxHR: maxHR, restingHR: restingHR,
                                    method: PuffinExperiment.effortMethod, sex: sex)
        if let e { effort.append(Point(ts: now, value: e)) }

        if ts - (today.stressTs.last ?? 0) >= Self.dayStepSeconds {
            today.stressTs.append(ts)
            today.stress.append(s)
            if let e {
                today.effortTs.append(ts)
                today.effort.append(e)
            }
        }

        let cutoff = now.addingTimeInterval(-Self.windowSeconds)
        stress.removeAll { $0.ts < cutoff }
        effort.removeAll { $0.ts < cutoff }

        if now.timeIntervalSince(lastSave) >= Self.saveEverySeconds {
            flush()
            if recordedDays.first != today.day { recordedDays = Self.storedDayKeys() }
        }
    }

    // MARK: Storage — Application Support/LiveTrace/<yyyy-MM-dd>.json, device-local only.

    nonisolated static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("LiveTrace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func url(_ key: String) -> URL? { directory?.appendingPathComponent("\(key).json") }

    private static func load(_ key: String) -> Day? {
        guard let u = url(key), let data = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(Day.self, from: data)
    }

    private static func save(_ day: Day) {
        guard let u = url(day.day), let data = try? JSONEncoder().encode(day) else { return }
        try? data.write(to: u, options: .atomic)
    }

    private static func storedDayKeys() -> [String] {
        guard let dir = directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted(by: >)
    }

    private static func prune() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) else { return }
        let oldest = dayKey(cutoff)
        for key in storedDayKeys() where key < oldest {
            if let u = url(key) { try? FileManager.default.removeItem(at: u) }
        }
    }
}

/// The Live screen card: a live 10-minute view that moves every second, and a Days view that shows any
/// recorded day's full stress + Effort lines with a summary.
struct LiveTraceCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @ObservedObject private var store = LiveTraceStore.shared
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    private enum Mode: String, CaseIterable { case live, days }
    @State private var mode: Mode = .live
    @State private var dayIndex = 0

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    var body: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 18) {
                header
                Picker("View", selection: $mode) {
                    Text("Live").tag(Mode.live)
                    Text("Days").tag(Mode.days)
                }
                .pickerStyle(.segmented)
                if mode == .live { liveBody } else { daysBody }
            }
        }
        .onAppear {
            LiveTraceStore.shared.attach(live, restingHR: model.repo.today?.restingHr,
                                         avgHrv: model.repo.today?.avgHrv,
                                         maxHR: model.profile.hrMax, sex: model.profile.sex)
        }
    }

    private var header: some View {
        HStack {
            Text("LIVE TRACE").strandOverline()
            Spacer()
            Circle()
                .fill(live.connected ? StrandPalette.statusPositive : StrandPalette.textTertiary)
                .frame(width: 7, height: 7)
            Text(live.connected ? "recording" : "not connected")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    // MARK: Live

    @ViewBuilder private var liveBody: some View {
        let now = Date()
        trace(title: "Stress", value: store.stress.last.map { StressTrace.formatLevel($0.value) },
              points: store.stress, yDomain: 0...3, xDomain: now.addingTimeInterval(-LiveTraceStore.windowSeconds)...now,
              xStride: .minute, xCount: 2, tint: StrandPalette.statusWarning)
        trace(title: "Effort", value: store.effort.last.map { UnitFormatter.effortDisplay($0.value, scale: effortScale) },
              points: store.effort, yDomain: effortDomain(store.effort),
              xDomain: now.addingTimeInterval(-LiveTraceStore.windowSeconds)...now,
              xStride: .minute, xCount: 2, tint: StrandPalette.strainColor(store.effort.last?.value ?? 0))
        Text(store.today.hrTs.isEmpty
             ? String(localized: "Connect your strap — the lines start moving with your live heart rate.")
             : String(localized: "Updated every second and saved on this device. Effort counts from midnight while the strap streams."))
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
    }

    // MARK: Days

    @ViewBuilder private var daysBody: some View {
        let keys = dayKeys
        if keys.isEmpty {
            Text("No days recorded yet. Keep your strap connected and today will appear here.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        } else {
            let i = min(dayIndex, keys.count - 1)
            let key = keys[i]
            let day = store.day(key) ?? LiveTraceStore.Day(day: key)
            HStack {
                Button { dayIndex = min(i + 1, keys.count - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(i >= keys.count - 1)
                Spacer()
                Text(dayLabel(key)).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Button { dayIndex = max(i - 1, 0) } label: { Image(systemName: "chevron.right") }
                    .disabled(i == 0)
            }
            .tint(StrandPalette.accent)
            HStack(spacing: 0) {
                summary("avg stress", day.avgStress.map(StressTrace.formatLevel))
                summary("peak stress", day.peakStress.map(StressTrace.formatLevel))
                summary("effort", day.finalEffort.map { UnitFormatter.effortDisplay($0, scale: effortScale) })
                summary("recorded", "\(day.recordedMinutes / 60)h \(day.recordedMinutes % 60)m")
            }
            let start = Calendar.current.startOfDay(for: day.stressPoints.first?.ts ?? Date())
            let end = start.addingTimeInterval(24 * 3600)
            trace(title: "Stress", value: nil, points: day.stressPoints, yDomain: 0...3, xDomain: start...end,
                  xStride: .hour, xCount: 6, tint: StrandPalette.statusWarning)
            trace(title: "Effort", value: nil, points: day.effortPoints, yDomain: effortDomain(day.effortPoints),
                  xDomain: start...end, xStride: .hour, xCount: 6,
                  tint: StrandPalette.strainColor(day.finalEffort ?? 0))
            Text("Only the time your strap was streaming live is recorded.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// Recorded days newest first, with today always first once it has any data.
    private var dayKeys: [String] {
        var keys = store.recordedDays
        if !store.today.hrTs.isEmpty, !keys.contains(store.today.day) { keys.insert(store.today.day, at: 0) }
        return keys
    }

    private func dayLabel(_ key: String) -> String {
        if key == LiveTraceStore.dayKey(Date()) { return String(localized: "Today") }
        if let y = Calendar.current.date(byAdding: .day, value: -1, to: Date()), key == LiveTraceStore.dayKey(y) {
            return String(localized: "Yesterday")
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: key) else { return key }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func summary(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—").font(StrandFont.number(17)).foregroundStyle(StrandPalette.textPrimary)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func effortDomain(_ pts: [LiveTraceStore.Point]) -> ClosedRange<Double> {
        0...max(10, (pts.map(\.value).max() ?? 0) * 1.2)
    }

    private func trace(title: LocalizedStringKey, value: String?, points: [LiveTraceStore.Point],
                       yDomain: ClosedRange<Double>, xDomain: ClosedRange<Date>,
                       xStride: Calendar.Component, xCount: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                if let value {
                    Text(value).font(StrandFont.number(22)).foregroundStyle(StrandPalette.textPrimary)
                }
            }
            Chart(points) { p in
                LineMark(x: .value("Time", p.ts), y: .value(title, p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .chartYScale(domain: yDomain)
            .chartXScale(domain: xDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: xStride, count: xCount)) { _ in
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
