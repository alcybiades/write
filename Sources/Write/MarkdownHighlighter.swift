import AppKit

extension NSAttributedString.Key {
    /// Marks markdown syntax characters (##, **, backticks, link urls…).
    /// The editor hides these glyphs unless the caret is on their paragraph.
    static let mdMarker = NSAttributedString.Key("mdMarker")
}

/// Live, in-place styling of markdown source. Content is styled; syntax
/// markers are tagged with `.mdMarker` so the view can render Obsidian-style
/// live preview (markers only visible on the active paragraph).
final class MarkdownHighlighter {

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private let heading = MarkdownHighlighter.regex(#"^(#{1,6})[ \t](.*)$"#)
    private let fence = MarkdownHighlighter.regex(#"^\s*(```|~~~)"#)
    private let task = MarkdownHighlighter.regex(#"^\s*[-*+][ \t]\[[ xX]\][ \t]"#)
    private let bullet = MarkdownHighlighter.regex(#"^\s*[-*+][ \t]"#)
    private let ordered = MarkdownHighlighter.regex(#"^\s*\d+[.)][ \t]"#)
    private let quote = MarkdownHighlighter.regex(#"^\s*(>[ \t]?)+"#)
    private let rule = MarkdownHighlighter.regex(#"^\s*([-*_])(\s*\1){2,}\s*$"#)
    // Shared with EditorTextView, which uses them to continue a span's style
    // when typing at its (visually concealed) closing delimiter and to layer
    // bold/italic instead of blindly nesting delimiters.
    static let boldItalicText = MarkdownHighlighter.regex(#"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#)
    static let boldText = MarkdownHighlighter.regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    // The opener may sit right after another delimiter (`***two** words*`);
    // the closer's guards are what keep this from matching inside `**bold**`.
    static let italicText = MarkdownHighlighter.regex(#"(?<!\w)(\*|_)(?![*_\s])(.+?)(?<![*_\s])\1(?![*\w])"#)
    static let inlineCode = MarkdownHighlighter.regex(#"`[^`\n]+`"#)
    private let linkText = MarkdownHighlighter.regex(#"\[([^\]\n]*)\]\(([^)\n]*)\)"#)
    static let colorSpan = MarkdownHighlighter.regex(#"<span style="color:#([0-9A-Fa-f]{6})">(.+?)</span>"#)

    private var isHighlighting = false

    /// Extra width added (via kerning) to the space after a list/quote
    /// marker so the gap is a consistent half-em. Proportional fonts have
    /// narrow spaces (~0.25em in Hoefler), which makes the gap after a
    /// bullet look cramped; monospace fonts need no correction.
    private var markerKern: CGFloat = 0

    private func computeMarkerKern() -> CGFloat {
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: Theme.baseFont]).width
        return max(0, Theme.fontSize * 0.5 - spaceWidth)
    }

    /// List/quote lines get a base indent, and their wrapped lines align
    /// with the text after the marker (a hanging indent, including the
    /// widened marker gap).
    private func hangingIndentStyle(prefix: String) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = Theme.lineHeightMultiple
        let baseIndent = Theme.fontSize
        style.firstLineHeadIndent = baseIndent
        style.headIndent = baseIndent + markerKern
            + (prefix as NSString).size(withAttributes: [.font: Theme.baseFont]).width
        return style
    }

    /// Widens the marker's trailing space via kerning.
    private func widenMarkerGap(_ ts: NSTextStorage, markerRange: NSRange) {
        guard markerKern > 0.1 else { return }
        ts.addAttribute(.kern, value: markerKern, range: NSRange(location: NSMaxRange(markerRange) - 1, length: 1))
    }

    private func headingScale(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 1.5
        case 2: return 1.3
        case 3: return 1.15
        default: return 1.0
        }
    }

    /// Restyles the whole document, then conceals every syntax marker by
    /// shrinking it to a ~0pt font — WYSIWYG: the markdown stays in the file
    /// but is never shown. Attribute-only concealment keeps TextKit layout
    /// fully consistent.
    func highlight(_ textStorage: NSTextStorage) {
        guard !isHighlighting else { return }
        isHighlighting = true
        defer { isHighlighting = false }

        let text = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        markerKern = computeMarkerKern()

        textStorage.beginEditing()
        textStorage.setAttributes(Theme.baseAttributes, range: fullRange)

        var inCodeBlock = false
        var lineStart = 0
        while lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            highlightLine(textStorage, text: text, lineRange: lineRange, inCodeBlock: &inCodeBlock)
            lineStart = NSMaxRange(lineRange)
        }

        let tiny = Theme.font(size: 0.1)
        textStorage.enumerateAttribute(.mdMarker, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            textStorage.addAttribute(.font, value: tiny, range: range)
        }
        textStorage.endEditing()
    }

    private func highlightLine(_ ts: NSTextStorage, text: NSString, lineRange: NSRange, inCodeBlock: inout Bool) {
        let line = text.substring(with: lineRange)
        let localRange = NSRange(location: 0, length: (line as NSString).length)
        func global(_ r: NSRange) -> NSRange { NSRange(location: lineRange.location + r.location, length: r.length) }
        func mark(_ r: NSRange) { ts.addAttribute(.mdMarker, value: true, range: r) }

        if fence.firstMatch(in: line, range: localRange) != nil {
            inCodeBlock.toggle()
            ts.addAttributes([.foregroundColor: Theme.dim, .backgroundColor: Theme.codeBackground], range: lineRange)
            return
        }
        if inCodeBlock {
            ts.addAttributes([.foregroundColor: Theme.code, .backgroundColor: Theme.codeBackground], range: lineRange)
            return
        }

        // Block-level rules.
        if let m = heading.firstMatch(in: line, range: localRange) {
            let level = m.range(at: 1).length
            let size = (Theme.fontSize * headingScale(level)).rounded()
            ts.addAttributes([
                .font: Theme.font(size: size),
                .foregroundColor: Theme.heading,
                .strokeWidth: -3.0,
                .paragraphStyle: Theme.paragraphStyle(spacingBefore: Theme.fontSize * 0.4),
            ], range: lineRange)
            let prefix = NSRange(location: lineRange.location, length: level + 1)
            ts.addAttributes([.foregroundColor: Theme.dim, .strokeWidth: 0.0], range: prefix)
            mark(prefix)
            return
        }
        if rule.firstMatch(in: line, range: localRange) != nil, line.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 {
            ts.addAttribute(.foregroundColor, value: Theme.dim, range: lineRange)
            return
        }
        if let m = quote.firstMatch(in: line, range: localRange) {
            ts.addAttribute(.foregroundColor, value: Theme.quote, range: lineRange)
            ts.addAttribute(.foregroundColor, value: Theme.dim, range: global(m.range))
            ts.addAttribute(.paragraphStyle, value: hangingIndentStyle(prefix: (line as NSString).substring(with: m.range)), range: lineRange)
            widenMarkerGap(ts, markerRange: global(m.range))
        } else if let m = task.firstMatch(in: line, range: localRange) {
            ts.addAttribute(.foregroundColor, value: Theme.listMarker, range: global(m.range))
            ts.addAttribute(.paragraphStyle, value: hangingIndentStyle(prefix: (line as NSString).substring(with: m.range)), range: lineRange)
            widenMarkerGap(ts, markerRange: global(m.range))
        } else if let m = bullet.firstMatch(in: line, range: localRange) {
            ts.addAttribute(.foregroundColor, value: Theme.listMarker, range: global(m.range))
            ts.addAttribute(.paragraphStyle, value: hangingIndentStyle(prefix: (line as NSString).substring(with: m.range)), range: lineRange)
            widenMarkerGap(ts, markerRange: global(m.range))
        } else if let m = ordered.firstMatch(in: line, range: localRange) {
            ts.addAttribute(.foregroundColor, value: Theme.listMarker, range: global(m.range))
            ts.addAttribute(.paragraphStyle, value: hangingIndentStyle(prefix: (line as NSString).substring(with: m.range)), range: lineRange)
            widenMarkerGap(ts, markerRange: global(m.range))
        }

        // Inline rules.
        Self.inlineCode.enumerateMatches(in: line, range: localRange) { m, _, _ in
            guard let m else { return }
            let r = global(m.range)
            ts.addAttributes([.foregroundColor: Theme.code, .backgroundColor: Theme.codeBackground], range: r)
            let open = NSRange(location: r.location, length: 1)
            let close = NSRange(location: NSMaxRange(r) - 1, length: 1)
            for tick in [open, close] {
                ts.addAttribute(.foregroundColor, value: Theme.dim, range: tick)
                mark(tick)
            }
        }
        // Triple delimiters are bold+italic in one span; handled first, and
        // excluded below so the two-star rule can't half-match inside them.
        var tripleRanges: [NSRange] = []
        Self.boldItalicText.enumerateMatches(in: line, range: localRange) { m, _, _ in
            guard let m else { return }
            tripleRanges.append(m.range)
            let r = global(m.range)
            ts.addAttributes([.foregroundColor: Theme.bold, .obliqueness: 0.18], range: r)
            let dLen = m.range(at: 1).length
            let open = NSRange(location: r.location, length: dLen)
            let close = NSRange(location: NSMaxRange(r) - dLen, length: dLen)
            for delim in [open, close] {
                ts.addAttributes([.foregroundColor: Theme.dim, .obliqueness: 0.0], range: delim)
                mark(delim)
            }
        }
        func insideTriple(_ range: NSRange) -> Bool {
            tripleRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        Self.boldText.enumerateMatches(in: line, range: localRange) { m, _, _ in
            guard let m, !insideTriple(m.range) else { return }
            let r = global(m.range)
            // Bold is a color accent, mirroring the terminal's bold override.
            ts.addAttribute(.foregroundColor, value: Theme.bold, range: r)
            let dLen = m.range(at: 1).length
            let open = NSRange(location: r.location, length: dLen)
            let close = NSRange(location: NSMaxRange(r) - dLen, length: dLen)
            for delim in [open, close] {
                ts.addAttribute(.foregroundColor, value: Theme.dim, range: delim)
                mark(delim)
            }
        }
        Self.italicText.enumerateMatches(in: line, range: localRange) { m, _, _ in
            guard let m, !insideTriple(m.range) else { return }
            let r = global(m.range)
            // Italics slant but keep whatever color the text already has.
            ts.addAttribute(.obliqueness, value: 0.18, range: r)
            let open = NSRange(location: r.location, length: 1)
            let close = NSRange(location: NSMaxRange(r) - 1, length: 1)
            for delim in [open, close] {
                ts.addAttributes([.foregroundColor: Theme.dim, .obliqueness: 0.0], range: delim)
                mark(delim)
            }
        }
        linkText.enumerateMatches(in: line, range: localRange) { m, _, _ in
            guard let m else { return }
            let r = global(m.range)
            let textRange = global(m.range(at: 1))
            ts.addAttribute(.foregroundColor, value: Theme.dim, range: r)
            ts.addAttributes([
                .foregroundColor: Theme.link,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: textRange)
            // Hide "[", then "](url)".
            mark(NSRange(location: r.location, length: 1))
            mark(NSRange(location: NSMaxRange(textRange), length: NSMaxRange(r) - NSMaxRange(textRange)))
        }
        // Applied last so an explicit color wins inside bold/italic runs.
        Self.colorSpan.enumerateMatches(in: line, range: localRange) { m, _, _ in
            guard let m else { return }
            let r = global(m.range)
            let contentRange = global(m.range(at: 2))
            if let color = NSColor(hexString: (line as NSString).substring(with: m.range(at: 1))) {
                ts.addAttribute(.foregroundColor, value: color, range: contentRange)
            }
            let openTag = NSRange(location: r.location, length: contentRange.location - r.location)
            let closeTag = NSRange(location: NSMaxRange(contentRange), length: NSMaxRange(r) - NSMaxRange(contentRange))
            for tag in [openTag, closeTag] {
                ts.addAttribute(.foregroundColor, value: Theme.dim, range: tag)
                mark(tag)
            }
        }
    }
}
