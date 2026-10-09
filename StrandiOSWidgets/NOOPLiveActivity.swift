import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for an active live-HR session — shown on the Lock Screen and in the Dynamic Island.
struct NOOPLiveActivity: Widget {
    /// The heart rate to draw: none once iOS has marked the banner stale. Each push is fresh for 30 s
    /// (`LiveActivityController.staleAfter`) and NOOP re-pushes a steady number well inside that, so a stale banner
    /// means the readings stopped — the strap off the wrist, or out of reach — even while NOOP itself is asleep and
    /// cannot say so: iOS redraws the banner at the stale date on its own.
    static func shownBpm(_ context: ActivityViewContext<NOOPActivityAttributes>) -> Int? {
        context.isStale ? nil : context.state.bpm
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            let terminal = CliTheme.resolve(context.state.theme ?? "")
            if terminal.isActive {
                TerminalBanner(theme: terminal, bpm: Self.shownBpm(context), state: context.state)
            } else {
                // Lock Screen / banner presentation.
                HStack(spacing: 14) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.title2)
                        .foregroundStyle(StrandPalette.statusCritical)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                        Text("\(Self.shownBpm(context).map(String.init) ?? "–") bpm")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Spacer()
                    // Charge + Effort (#446) on the banner, mirroring the Dynamic Island expanded stats.
                    HStack(spacing: 12) {
                        if let r = context.state.recovery {
                            bannerStat(label: "Charge", value: "\(r)%")
                        }
                        if let e = context.state.effort {
                            bannerStat(label: "Effort", value: "\(e)")
                        }
                    }
                }
                .padding()
                .activityBackgroundTint(StrandPalette.surfaceBase)
                .activitySystemActionForegroundColor(StrandPalette.textPrimary)
            }
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(Self.shownBpm(context).map(String.init) ?? "–")", systemImage: "heart.fill")
                        .foregroundStyle(StrandPalette.statusCritical)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // Charge + Effort (#446) — one more stat alongside the leading live HR.
                    HStack(spacing: 10) {
                        if let r = context.state.recovery {
                            statColumn(label: "Charge", value: "\(r)%")
                        }
                        if let e = context.state.effort {
                            statColumn(label: "Effort", value: "\(e)")
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.title).font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
            } compactTrailing: {
                Text("\(Self.shownBpm(context).map(String.init) ?? "–")")
            } minimal: {
                Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
            }
        }
    }
}

/// Lock-Screen banner stat column (label over value). File-scope because the `ActivityConfiguration`
/// content closure isn't a method of `NOOPLiveActivity`.
///
/// #759 - the label and value are CENTRE-aligned so each value sits directly under its own label. The
/// old `.trailing` alignment right-pinned both to the column's edge: when the value was narrower than
/// the label (e.g. "12" under "Effort") it drifted to the label's right edge instead of under it, which
/// read as "the number doesn't line up with its label". `fixedSize` stops either line truncating so the
/// pairing is never clipped at narrow widths.
@ViewBuilder
private func bannerStat(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 2) {
        Text(label).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
        Text(value).font(.headline).foregroundStyle(StrandPalette.textPrimary)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}

/// Dynamic Island expanded-region stat column (label over value). File-scope for the same reason as
/// `bannerStat`. #759 - centre-aligned + `fixedSize` for the same value-under-its-label fix as the banner.
@ViewBuilder
private func statColumn(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 1) {
        Text(label).font(.caption2).foregroundStyle(.secondary)
        Text(value).font(.headline)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}

/// The Lock-Screen banner in a terminal theme (Claude / Grok): a prompt line, the live heart rate as the
/// command's output, and the day's stats as key/value pairs, in SF Mono on the theme's own canvas.
private struct TerminalBanner: View {
    let theme: CliTheme
    let bpm: Int?
    let state: NOOPActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("*").foregroundStyle(theme.accent)
                Text("~/noop").foregroundStyle(theme.bannerMuted)
                Spacer()
                Circle().fill(bpm == nil ? theme.bannerMuted : theme.accent).frame(width: 6, height: 6)
                Text(bpm == nil ? "offline" : "live").foregroundStyle(theme.bannerMuted)
            }
            .font(.system(.caption, design: .monospaced))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(">").foregroundStyle(theme.accent)
                Text(bpm.map(String.init) ?? "--")
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.bannerText)
                Text("bpm").foregroundStyle(theme.bannerMuted)
                Spacer()
            }
            .font(.system(.body, design: .monospaced))
            HStack(spacing: 14) {
                if let s = state.stressTenths { stat("stress", String(format: "%.1f", Double(s) / 10)) }
                if let e = state.effort { stat("effort", "\(e)") }
                if let r = state.recovery { stat("charge", "\(r)%") }
                Spacer()
            }
        }
        .padding()
        .activityBackgroundTint(theme.bannerCanvas)
        .activitySystemActionForegroundColor(theme.bannerText)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(theme.bannerMuted)
            Text(value).foregroundStyle(theme.bannerText)
        }
        .font(.system(.caption, design: .monospaced))
    }
}
