#if os(iOS)
import Foundation
import ActivityKit

/// Live Activity attributes for an active live-HR / workout session. Shared between the app (which
/// starts/updates the activity) and the widget extension (which renders it on the Lock Screen and in
/// the Dynamic Island).
public struct NOOPActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var bpm: Int?
        public var recovery: Int?
        public var bonded: Bool
        // Effort / strain on NOOP's 0–100 axis (#446) — one more stat in the Dynamic Island expanded
        // region. OPTIONAL with a nil default so an activity started by an older build still decodes.
        public var effort: Int?
        /// Live stress (0-3) in tenths, from the Live Trace recorder. Optional so older states decode.
        public var stressTenths: Int?
        /// The active terminal theme raw value ("claude" / "grok"), nil or "off" for the standard banner.
        public var theme: String?

        public init(bpm: Int?, recovery: Int?, bonded: Bool, effort: Int? = nil,
                    stressTenths: Int? = nil, theme: String? = nil) {
            self.bpm = bpm
            self.recovery = recovery
            self.bonded = bonded
            self.effort = effort
            self.stressTenths = stressTenths
            self.theme = theme
        }
    }

    /// Static title shown for the session.
    public var title: String

    public init(title: String = "Live HR") {
        self.title = title
    }
}
#endif
