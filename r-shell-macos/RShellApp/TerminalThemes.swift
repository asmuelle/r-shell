import AppKit
import SwiftTerm

/// Named colour scheme applied to `SwiftTerm.TerminalView`. Picks bg/fg/caret
/// for the chrome and a 16-entry ANSI palette for the cell colours.
///
/// The "system" / "light" / "dark" entries apply only the chrome colours;
/// the underlying ANSI palette is left at SwiftTerm's defaults (which are
/// already legible on every system appearance). The named themes
/// (Solarized, Dracula, …) override both layers via `installColors`.
struct TerminalTheme: Identifiable {
    let id: String          // matches @AppStorage("terminalTheme")
    let label: String       // shown in Settings picker
    let background: NSColor
    let foreground: NSColor
    let caret: NSColor
    /// `nil` ⇒ leave SwiftTerm's defaults; non-nil overrides via `installColors`.
    let ansiPalette: [SwiftTerm.Color]?

    /// Apply the theme to a SwiftTerm view. Idempotent — safe to call from
    /// `updateNSView` on every Settings change.
    func apply(to term: SwiftTerm.TerminalView) {
        term.nativeBackgroundColor = background
        term.nativeForegroundColor = foreground
        term.caretColor = caret
        if let ansi = ansiPalette {
            term.installColors(ansi)
        }
    }

    static func resolve(_ id: String) -> TerminalTheme {
        switch id {
        case "light":           return .light
        case "dark":            return .dark
        case "solarized-dark":  return .solarizedDark
        case "dracula":         return .dracula
        case "nord":            return .nord
        case "tomorrow-night":  return .tomorrowNight
        default:                return .system
        }
    }

    /// Order shown in the Settings picker.
    static let all: [TerminalTheme] = [
        .system, .light, .dark, .solarizedDark, .dracula, .nord, .tomorrowNight,
    ]
}

// MARK: - Built-in themes

extension TerminalTheme {
    static let system = TerminalTheme(
        id: "system",
        label: "Follow system",
        background: NSColor.textBackgroundColor,
        foreground: NSColor.textColor,
        caret: NSColor.textColor,
        ansiPalette: nil
    )

    static let light = TerminalTheme(
        id: "light",
        label: "Light",
        background: .white,
        foreground: .black,
        caret: .black,
        ansiPalette: nil
    )

    static let dark = TerminalTheme(
        id: "dark",
        label: "Dark",
        background: NSColor(calibratedWhite: 0.07, alpha: 1),
        foreground: NSColor(calibratedWhite: 0.92, alpha: 1),
        caret: NSColor(calibratedWhite: 0.92, alpha: 1),
        ansiPalette: nil
    )

    /// Solarized Dark — Ethan Schoonover, https://ethanschoonover.com/solarized/
    static let solarizedDark = TerminalTheme(
        id: "solarized-dark",
        label: "Solarized Dark",
        background: HexColor.ns("002b36"),
        foreground: HexColor.ns("839496"),
        caret: HexColor.ns("839496"),
        ansiPalette: [
            HexColor.term("073642"), HexColor.term("dc322f"), HexColor.term("859900"), HexColor.term("b58900"),
            HexColor.term("268bd2"), HexColor.term("d33682"), HexColor.term("2aa198"), HexColor.term("eee8d5"),
            HexColor.term("002b36"), HexColor.term("cb4b16"), HexColor.term("586e75"), HexColor.term("657b83"),
            HexColor.term("839496"), HexColor.term("6c71c4"), HexColor.term("93a1a1"), HexColor.term("fdf6e3"),
        ]
    )

    /// Dracula — https://draculatheme.com/
    static let dracula = TerminalTheme(
        id: "dracula",
        label: "Dracula",
        background: HexColor.ns("282a36"),
        foreground: HexColor.ns("f8f8f2"),
        caret: HexColor.ns("f8f8f2"),
        ansiPalette: [
            HexColor.term("21222c"), HexColor.term("ff5555"), HexColor.term("50fa7b"), HexColor.term("f1fa8c"),
            HexColor.term("bd93f9"), HexColor.term("ff79c6"), HexColor.term("8be9fd"), HexColor.term("f8f8f2"),
            HexColor.term("6272a4"), HexColor.term("ff6e6e"), HexColor.term("69ff94"), HexColor.term("ffffa5"),
            HexColor.term("d6acff"), HexColor.term("ff92df"), HexColor.term("a4ffff"), HexColor.term("ffffff"),
        ]
    )

    /// Nord — https://www.nordtheme.com/
    static let nord = TerminalTheme(
        id: "nord",
        label: "Nord",
        background: HexColor.ns("2e3440"),
        foreground: HexColor.ns("d8dee9"),
        caret: HexColor.ns("d8dee9"),
        ansiPalette: [
            HexColor.term("3b4252"), HexColor.term("bf616a"), HexColor.term("a3be8c"), HexColor.term("ebcb8b"),
            HexColor.term("81a1c1"), HexColor.term("b48ead"), HexColor.term("88c0d0"), HexColor.term("e5e9f0"),
            HexColor.term("4c566a"), HexColor.term("bf616a"), HexColor.term("a3be8c"), HexColor.term("ebcb8b"),
            HexColor.term("81a1c1"), HexColor.term("b48ead"), HexColor.term("8fbcbb"), HexColor.term("eceff4"),
        ]
    )

    /// Tomorrow Night — Chris Kempson, https://github.com/chriskempson/tomorrow-theme
    static let tomorrowNight = TerminalTheme(
        id: "tomorrow-night",
        label: "Tomorrow Night",
        background: HexColor.ns("1d1f21"),
        foreground: HexColor.ns("c5c8c6"),
        caret: HexColor.ns("c5c8c6"),
        ansiPalette: [
            HexColor.term("1d1f21"), HexColor.term("cc6666"), HexColor.term("b5bd68"), HexColor.term("f0c674"),
            HexColor.term("81a2be"), HexColor.term("b294bb"), HexColor.term("8abeb7"), HexColor.term("c5c8c6"),
            HexColor.term("969896"), HexColor.term("cc6666"), HexColor.term("b5bd68"), HexColor.term("f0c674"),
            HexColor.term("81a2be"), HexColor.term("b294bb"), HexColor.term("8abeb7"), HexColor.term("ffffff"),
        ]
    )
}

// MARK: - Hex helpers

/// 6-char hex (`"ff79c6"`) to NSColor / SwiftTerm.Color. Crashes loudly on
/// malformed input — our palette tables are static literals, so a typo
/// should be caught the first time the theme is loaded.
private enum HexColor {
    static func ns(_ hex: String) -> NSColor {
        let (r, g, b) = parse(hex)
        return NSColor(
            calibratedRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }

    static func term(_ hex: String) -> SwiftTerm.Color {
        let (r, g, b) = parse(hex)
        // SwiftTerm.Color uses 16-bit channels (0…65535). `value * 257`
        // maps 0xFF cleanly onto 0xFFFF (rather than `value << 8` which
        // tops out at 0xFF00).
        return SwiftTerm.Color(
            red: UInt16(r) &* 257,
            green: UInt16(g) &* 257,
            blue: UInt16(b) &* 257
        )
    }

    private static func parse(_ hex: String) -> (UInt8, UInt8, UInt8) {
        precondition(hex.count == 6, "expected 6-char hex, got \(hex)")
        let bytes = stride(from: 0, to: 6, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            guard let v = UInt8(hex[start..<end], radix: 16) else {
                preconditionFailure("malformed hex segment in \(hex)")
            }
            return v
        }
        return (bytes[0], bytes[1], bytes[2])
    }
}
