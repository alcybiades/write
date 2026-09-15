import AppKit

extension NSColor {
    convenience init?(hexString: String) {
        var value: UInt64 = 0
        guard Scanner(string: hexString).scanHexInt64(&value), value <= 0xFFFFFF else { return nil }
        self.init(hex: UInt32(value))
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

/// "Neon Noir" — mirrors ~/.wezterm.lua.
enum Theme {
    static let background = NSColor(hex: 0x141414)
    static let backgroundOpacity: CGFloat = 0.60

    static let foreground = NSColor(hex: 0x63D0FF)
    static let bold = NSColor(hex: 0xFFFFFF)
    static let heading = NSColor(hex: 0xA4BEEF)
    static let italic = NSColor(hex: 0xD7E0FF)
    static let code = NSColor(hex: 0x55E6A5)
    static let codeAmber = NSColor(hex: 0xFFB86C)
    static let dim = NSColor(hex: 0x526078)
    static let listMarker = NSColor(hex: 0xFFD166)
    static let quote = NSColor(hex: 0xBF8EE8)
    static let link = NSColor(hex: 0x7DD3FC)
    static let cursor = NSColor(hex: 0x727272)
    static let selection = NSColor(hex: 0x334A7D)
    static let codeBackground = NSColor(hex: 0x2E2E2E, alpha: 0.5)

    /// Monospaced font for code, independent of the body family.
    /// (The system monospaced font is SF Mono on modern macOS.)
    static func codeFont(size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static let lineHeightMultiple: CGFloat = 1.16
    static let padding: CGFloat = 28
    /// Modern macOS window rounding; the tab strip inset follows it.
    static let windowCornerRadius: CGFloat = 26

    /// Text colors offered by the selection toolbar. Serialized to markdown
    /// as inline HTML spans, so files stay portable.
    static let accentColors: [(name: String, hex: String)] = [
        ("Blue", "72A7FF"),
        ("Red", "FF5C5C"),
        ("Green", "55E6A5"),
        ("Lavender", "BF8EE8"),
        ("Orange", "FF9F45"),
        ("Dandelion", "FFD166"),
        ("Leaf Green", "86C56A"),
        ("Coral", "FF8A7A"),
    ]
    /// Prose column cap: about half a MacBook screen minus 80pt padding per
    /// side. Past this the window just grows its horizontal padding.
    static let maxTextWidth: CGFloat = 720

    static var fontSize: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: "fontSize")
            return stored > 0 ? CGFloat(stored) : 20
        }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: "fontSize")
        }
    }

    static let defaultFontFamily = "Classic Console Neue"

    static var fontFamily: String {
        get { UserDefaults.standard.string(forKey: "fontFamily") ?? defaultFontFamily }
        set { UserDefaults.standard.set(newValue, forKey: "fontFamily") }
    }

    private static let fallbackFontNames = ["ClassicConsoleNeue", "JetBrainsMono-Regular", "SFMono-Regular", "Menlo"]

    static func font(size: CGFloat) -> NSFont {
        if let font = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: size) {
            return font
        }
        for name in fallbackFontNames {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static var baseFont: NSFont { font(size: fontSize) }

    private static var boldCache: [String: (font: NSFont, synthetic: Bool)] = [:]

    /// The family's real bold face when it has one; otherwise the regular
    /// face flagged `synthetic` so callers can fake weight with stroke.
    static func boldFont(size: CGFloat) -> (font: NSFont, synthetic: Bool) {
        let key = "\(fontFamily)#\(size)"
        if let cached = boldCache[key] { return cached }
        let regular = font(size: size)
        let bold = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        let synthetic = !NSFontManager.shared.traits(of: bold).contains(.boldFontMask)
        let result = (synthetic ? regular : bold, synthetic)
        boldCache[key] = result
        return result
    }

    private static var italicCache: [String: (font: NSFont, synthetic: Bool)] = [:]

    /// The family's real italic face; `synthetic` means fake it with skew.
    static func italicFont(size: CGFloat) -> (font: NSFont, synthetic: Bool) {
        let key = "\(fontFamily)#\(size)"
        if let cached = italicCache[key] { return cached }
        let regular = font(size: size)
        let italic = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
        let synthetic = !NSFontManager.shared.traits(of: italic).contains(.italicFontMask)
        let result = (synthetic ? regular : italic, synthetic)
        italicCache[key] = result
        return result
    }

    private static var boldItalicCache: [String: (font: NSFont, syntheticBold: Bool, syntheticItalic: Bool)] = [:]

    /// The family's bold-italic face, degrading gracefully: real bold with
    /// synthetic slant, or regular with synthetic weight and slant.
    static func boldItalicFont(size: CGFloat) -> (font: NSFont, syntheticBold: Bool, syntheticItalic: Bool) {
        let key = "\(fontFamily)#\(size)"
        if let cached = boldItalicCache[key] { return cached }
        let (bold, syntheticBold) = boldFont(size: size)
        let combined = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        let traits = NSFontManager.shared.traits(of: combined)
        let hasItalic = traits.contains(.italicFontMask)
        let hasBold = traits.contains(.boldFontMask) || syntheticBold
        let result: (NSFont, Bool, Bool) = hasItalic && hasBold
            ? (combined, syntheticBold, false)
            : (bold, syntheticBold, true)
        boldItalicCache[key] = result
        return result
    }

    static func paragraphStyle(spacingBefore: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        style.paragraphSpacingBefore = spacingBefore
        return style
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: foreground,
            .paragraphStyle: paragraphStyle(),
        ]
    }
}
