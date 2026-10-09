import SwiftUI

// MARK: - NOOP visual foundation
//
// These tokens describe the visual treatment used by NOOP's existing views. They deliberately
// contain no navigation, state, or domain semantics: screens keep their current hierarchy and data
// bindings, while cards, gauges, typography, and chrome share one maintainable source of truth.

public enum NoopVisualStyle {
    /// The active terminal theme (`CliTheme`). Set at the app root via `.noopCliTheme(_:)`; the surface and
    /// text tokens below read it when they resolve, so the whole chrome re-skins without per-view plumbing.
    public static var cliTheme: CliTheme = .off

    // Neutral, low-chroma surfaces sampled from the supplied dark-mode reference. Each also carries the
    // Claude (warm charcoal) and Grok (near-black) dark values used while a terminal theme is active.
    public static let canvas = Color(light: "#F3F4F6", dark: "#1D1E23", claude: "#151413", grok: "#000000")
    public static let surface = Color(light: "#FFFFFF", dark: "#2A2C34", claude: "#1C1B1A", grok: "#0B0B0B")
    public static let surfaceTop = Color(light: "#FFFFFF", dark: "#30323B", claude: "#1E1D1C", grok: "#0C0C0C")
    public static let surfaceBottom = Color(light: "#F4F5F7", dark: "#282A31", claude: "#1A1918", grok: "#0A0A0A")
    public static let inset = Color(light: "#E8E9ED", dark: "#23252C", claude: "#232220", grok: "#141414")

    public static let border = Color(light: "#D8DAE0", dark: "#373A44", claude: "#34322E", grok: "#262626")
    public static let borderHighlight = Color(light: "#FFFFFF", dark: "#4B4E59", claude: "#3C3A35", grok: "#2C2C2C")
    public static let divider = Color(light: "#E4E5E9", dark: "#383A43", claude: "#2C2A27", grok: "#1F1F1F")

    public static let primaryText = Color(light: "#17181C", dark: "#F7F7FA", claude: "#F2F0E8", grok: "#EDEDED")
    public static let secondaryText = Color(light: "#555861", dark: "#C3C4CA", claude: "#B8B5AA", grok: "#A3A3A3")
    public static let tertiaryText = Color(light: "#7D808A", dark: "#7D7F88", claude: "#7F7C73", grok: "#6B6B6B")

    public static let mint = Color(light: "#149A78", dark: "#69DDB8")
    public static let mintDeep = Color(light: "#0D765C", dark: "#13A982")
    public static let mintGlow = Color(light: "#38C99E", dark: "#54E6BD")

    public static let cardRadius: CGFloat = 22
    public static let compactRadius: CGFloat = 16
    public static let pillRadius: CGFloat = 999
    public static let pagePadding: CGFloat = 16
    public static let cardPadding: CGFloat = 16
    public static let itemGap: CGFloat = 12
    public static let sectionGap: CGFloat = 26
}

/// A terminal-inspired look: a warm dark canvas, a monospace face and a CLI accent. `.claude` follows the
/// Claude Code terminal (warm charcoal + coral); `.grok` is near-black with gold. The app roots force dark
/// mode while active. Stored at `CliTheme.storageKey`, applied at each app root via `.noopCliTheme(_:)`.
public enum CliTheme: String, CaseIterable, Identifiable, Sendable {
    case off, claude, grok

    public var id: String { rawValue }
    public static let storageKey = "noop.cliTheme"

    public var label: String {
        switch self {
        case .off:    return String(localized: "Off", bundle: .module)
        case .claude: return "Claude"
        case .grok:   return "Grok"
        }
    }

    public var isActive: Bool { self != .off }

    /// The accent that overrides the user's accent choice while this theme is active.
    var accentHex: String? {
        switch self {
        case .off:    return nil
        case .claude: return "#D97757"
        case .grok:   return "#E8B84B"
        }
    }

    public static func resolve(_ raw: String) -> CliTheme { CliTheme(rawValue: raw) ?? .off }
}

extension Color {
    /// A scheme-aware token whose DARK value switches with the active `CliTheme`. All hexes are parsed
    /// once here; the provider only picks between ready tuples (see `Color(light:dark:)`, #2393).
    init(light: String, dark: String, claude: String, grok: String) {
        let c = (light: Color.sRGBComponents(hex: light), dark: Color.sRGBComponents(hex: dark),
                 claude: Color.sRGBComponents(hex: claude), grok: Color.sRGBComponents(hex: grok))
        func pickDark() -> (r: Double, g: Double, b: Double, a: Double) {
            switch NoopVisualStyle.cliTheme {
            case .off:    return c.dark
            case .claude: return c.claude
            case .grok:   return c.grok
            }
        }
        #if os(watchOS)
        let d = c.dark
        self.init(.sRGB, red: d.r, green: d.g, blue: d.b, opacity: d.a)
        #elseif canImport(UIKit)
        self.init(UIColor { trait in
            let v = trait.userInterfaceStyle == .dark ? pickDark() : c.light
            return UIColor(red: CGFloat(v.r), green: CGFloat(v.g), blue: CGFloat(v.b), alpha: CGFloat(v.a))
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = isDark ? pickDark() : c.light
            return NSColor(srgbRed: CGFloat(v.r), green: CGFloat(v.g), blue: CGFloat(v.b), alpha: CGFloat(v.a))
        })
        #else
        let d = c.dark
        self.init(.sRGB, red: d.r, green: d.g, blue: d.b, opacity: d.a)
        #endif
    }
}

public extension View {
    /// Applies the terminal theme: sets `NoopVisualStyle.cliTheme` and keys the content so a change
    /// re-renders live. Apply at each app root; the root also forces `.dark` while a theme is active.
    @ViewBuilder
    func noopCliTheme(_ raw: String) -> some View {
        let theme = CliTheme.resolve(raw)
        let _ = (NoopVisualStyle.cliTheme = theme)
        let keyed = self.id("noop.cliTheme.\(raw)")
        // Monospace for every system font that does not pin its own design (StrandFont follows the theme).
        if #available(iOS 16.1, macOS 13.0, watchOS 9.1, *) {
            keyed.fontDesign(theme.isActive ? .monospaced : nil)
        } else {
            keyed
        }
    }
}

/// Shared card/panel treatment: a solid surface on iOS, gradient and soft elevation elsewhere.
/// `tint` is intentionally faint so metric identity never turns the whole card into a coloured tile.
public struct NoopPanelSurface: View {
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var elevated: Bool
    public var surfaceOpacity: Double
    #if !os(iOS)
    @Environment(\.colorScheme) private var scheme
    #endif

    public init(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.elevated = elevated
        self.surfaceOpacity = surfaceOpacity
    }

    public var body: some View {
        // Terminal themes draw squarer cards with a crisp, untinted 1px edge.
        let terminal = NoopVisualStyle.cliTheme.isActive
        let shape = RoundedRectangle(cornerRadius: terminal ? min(cornerRadius, 8) : cornerRadius, style: .continuous)
        #if os(iOS)
        // Scrolling stacks contain many panels. Layered translucent gradients and blurred shadows
        // multiply their compositing work, so iOS uses one theme-aware fill and a thin tinted rim.
        // This changes decorative depth only; card geometry and the design-system colors stay the same.
        shape
            .fill(NoopVisualStyle.surface)
            .overlay(shape.strokeBorder(
                terminal ? NoopVisualStyle.border
                         : tint?.opacity(0.14) ?? NoopVisualStyle.borderHighlight.opacity(elevated ? 0.9 : 0.65),
                lineWidth: terminal ? 1 : 0.8
            ))
            .opacity(surfaceOpacity)
        #else
        shape
            .fill(
                LinearGradient(
                    colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surfaceBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                if let tint {
                    shape.fill(
                        LinearGradient(
                            colors: [tint.opacity(0.055), tint.opacity(0.012), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [NoopVisualStyle.borderHighlight.opacity(0.72), NoopVisualStyle.border.opacity(0.52)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            )
            .shadow(
                color: scheme == .dark ? .black.opacity(elevated ? 0.34 : 0.18) : .black.opacity(0.10),
                radius: elevated ? 18 : 9,
                x: 0,
                y: elevated ? 10 : 5
            )
            .opacity(surfaceOpacity)
        #endif
    }
}

/// Shared edge-to-edge chrome for sheet and split-view headers. Unlike a card it has no
/// rounded outline or elevation, but it uses the same top-lit surface ramp and divider token.
public struct NoopChromeSurface: View {
    public init() {}

    public var body: some View {
        LinearGradient(
            colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surfaceBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NoopVisualStyle.divider)
                .frame(height: 0.5)
        }
    }
}

public extension View {
    func noopPanel(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) -> some View {
        background {
            NoopPanelSurface(
                tint: tint,
                cornerRadius: cornerRadius,
                elevated: elevated,
                surfaceOpacity: surfaceOpacity
            )
        }
    }
}
