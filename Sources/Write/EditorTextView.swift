import AppKit

/// Markdown text view: mouse-first editing with terminal aesthetics, live
/// Obsidian-style preview (syntax markers hidden except on the caret's
/// paragraph), slash commands, format shortcuts, and list continuation.
final class EditorTextView: NSTextView {

    private let highlighter = MarkdownHighlighter()

    /// Extra space above the text for the inline document title. The inset
    /// carries half of it, and the origin shift moves that half to the top,
    /// so the bottom keeps the plain padding.
    var extraTopInset: CGFloat = 0

    override var textContainerOrigin: NSPoint {
        var origin = super.textContainerOrigin
        origin.y += extraTopInset / 2
        return origin
    }

    // MARK: - Setup

    func configure() {
        drawsBackground = false
        isRichText = true
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        smartInsertDeleteEnabled = false

        insertionPointColor = Theme.cursor
        selectedTextAttributes = [
            .backgroundColor: Theme.selection,
            .foregroundColor: NSColor(hex: 0xF8FAFC),
        ]
        typingAttributes = Theme.baseAttributes

        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionChanged),
            name: NSTextView.didChangeSelectionNotification, object: self)
    }

    func rehighlight() {
        if let textStorage { highlighter.highlight(textStorage) }
        typingAttributes = Theme.baseAttributes
    }

    override func didChangeText() {
        super.didChangeText()
        rehighlight()
    }

    // MARK: - WYSIWYG: the caret skips concealed markers

    /// The full run of concealed marker characters containing `index`.
    private func concealedRun(containing index: Int) -> NSRange? {
        guard let textStorage, index >= 0, index < textStorage.length else { return nil }
        var effective = NSRange()
        let full = NSRange(location: 0, length: textStorage.length)
        guard textStorage.attribute(.mdMarker, at: index,
                                    longestEffectiveRange: &effective, in: full) != nil else { return nil }
        return effective
    }

    private var navigating = false

    override func moveLeft(_ sender: Any?) {
        navigating = true
        defer { navigating = false }
        super.moveLeft(sender)
        let caret = selectedRange().location
        if let run = concealedRun(containing: caret), caret > run.location {
            setSelectedRange(NSRange(location: run.location, length: 0))
        }
    }

    override func moveRight(_ sender: Any?) {
        navigating = true
        defer { navigating = false }
        super.moveRight(sender)
        let caret = selectedRange().location
        if caret > 0, let run = concealedRun(containing: caret - 1), caret < NSMaxRange(run) {
            setSelectedRange(NSRange(location: NSMaxRange(run), length: 0))
        }
    }

    /// Clicks and vertical movement can land the caret inside a concealed
    /// run; snap it to the nearer edge.
    @objc private func selectionChanged() {
        guard !navigating else { return }
        let sel = selectedRange()
        guard sel.length == 0, sel.location > 0 else { return }
        guard let run = concealedRun(containing: sel.location),
              sel.location > run.location,
              let leftRun = concealedRun(containing: sel.location - 1),
              leftRun == run else { return }
        let snapped = (sel.location - run.location <= NSMaxRange(run) - sel.location)
            ? run.location : NSMaxRange(run)
        setSelectedRange(NSRange(location: snapped, length: 0))
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0, sel.location > 0,
              let run = concealedRun(containing: sel.location - 1) else {
            super.deleteBackward(sender)
            return
        }
        let ns = string as NSString
        let paragraph = ns.paragraphRange(for: sel)
        if run.location == paragraph.location {
            // A concealed block marker (e.g. a heading's "# ") at the start
            // of the paragraph: backspace un-formats the block, Notion-style.
            insertText("", replacementRange: run)
            return
        }
        // Delete the nearest visible character to the left of the run.
        var index = run.location - 1
        while index >= 0, let outer = concealedRun(containing: index) {
            if outer.location == paragraph.location {
                insertText("", replacementRange: NSRange(location: outer.location, length: NSMaxRange(run) - outer.location))
                return
            }
            index = outer.location - 1
        }
        guard index >= 0 else {
            super.deleteBackward(sender)
            return
        }
        let charRange = ns.rangeOfComposedCharacterSequence(at: index)
        insertText("", replacementRange: charRange)
    }

    override func deleteForward(_ sender: Any?) {
        let sel = selectedRange()
        let ns = string as NSString
        guard sel.length == 0, sel.location < ns.length,
              let run = concealedRun(containing: sel.location) else {
            super.deleteForward(sender)
            return
        }
        // Delete the nearest visible character to the right of the run.
        var index = NSMaxRange(run)
        while index < ns.length, let outer = concealedRun(containing: index) {
            index = NSMaxRange(outer)
        }
        guard index < ns.length else {
            super.deleteForward(sender)
            return
        }
        let charRange = ns.rangeOfComposedCharacterSequence(at: index)
        insertText("", replacementRange: charRange)
        setSelectedRange(NSRange(location: sel.location, length: 0))
    }

    // MARK: - Continuing inline styles at span edges

    /// Inline spans whose style continues when typing at their end:
    /// (regex, closing delimiter length; nil = length of capture group 1).
    private static let continuableSpans: [(NSRegularExpression, Int?)] = [
        (MarkdownHighlighter.boldItalicText, nil),
        (MarkdownHighlighter.boldText, nil),
        (MarkdownHighlighter.italicText, 1),
        (MarkdownHighlighter.inlineCode, 1),
        (MarkdownHighlighter.colorSpan, ("</span>" as NSString).length),
    ]

    /// A caret just past a span's closing delimiter is visually at the end of
    /// the styled text (the markers are concealed), so typing there should
    /// continue the style: returns the position inside the delimiter(s).
    private func styleContinuationLocation(for caret: Int) -> Int {
        let ns = string as NSString
        var location = caret
        var moved = true
        while moved, location > 0, location <= ns.length {
            moved = false
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let line = ns.substring(with: lineRange)
            let local = NSRange(location: 0, length: (line as NSString).length)
            let localCaret = location - lineRange.location
            for (regex, closeLength) in Self.continuableSpans where !moved {
                regex.enumerateMatches(in: line, range: local) { m, _, stop in
                    guard let m, NSMaxRange(m.range) == localCaret else { return }
                    location -= closeLength ?? m.range(at: 1).length
                    moved = true
                    stop.pointee = true
                }
            }
        }
        return location
    }

    // MARK: - Slash commands

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let inserted = (string as? String) ?? (string as? NSAttributedString)?.string
        // Typing at the end of a bold/italic/code/color span continues the
        // style. Whitespace stays outside: a trailing space inside the
        // delimiters would invalidate the markdown span.
        if replacementRange.location == NSNotFound, !hasMarkedText(),
           let first = inserted?.first, !first.isWhitespace {
            let sel = selectedRange()
            if sel.length == 0 {
                let inside = styleContinuationLocation(for: sel.location)
                if inside != sel.location {
                    setSelectedRange(NSRange(location: inside, length: 0))
                }
            }
        }
        super.insertText(string, replacementRange: replacementRange)
        guard inserted == "/" else { return }
        let ns = self.string as NSString
        let caret = selectedRange().location
        guard caret > 0 else { return }
        let lineRange = ns.lineRange(for: NSRange(location: caret - 1, length: 0))
        let prefix = ns.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
        if prefix.trimmingCharacters(in: .whitespaces) == "/" {
            showSlashMenu(slashRange: NSRange(location: caret - 1, length: 1))
        }
    }

    private struct SlashCommand {
        let title: String
        let snippet: String
        /// Caret offset within the snippet after insertion; nil = end.
        let caretOffset: Int?
    }

    private static let slashCommands: [SlashCommand?] = [
        SlashCommand(title: "# Heading 1", snippet: "# ", caretOffset: nil),
        SlashCommand(title: "## Heading 2", snippet: "## ", caretOffset: nil),
        SlashCommand(title: "### Heading 3", snippet: "### ", caretOffset: nil),
        nil,
        SlashCommand(title: "- Bullet list", snippet: "- ", caretOffset: nil),
        SlashCommand(title: "1. Numbered list", snippet: "1. ", caretOffset: nil),
        SlashCommand(title: "[ ] Task", snippet: "- [ ] ", caretOffset: nil),
        nil,
        SlashCommand(title: "> Quote", snippet: "> ", caretOffset: nil),
        SlashCommand(title: "``` Code block", snippet: "```\n\n```", caretOffset: 4),
        SlashCommand(title: "--- Divider", snippet: "---\n", caretOffset: nil),
    ]

    private var pendingSlashRange: NSRange?

    private func showSlashMenu(slashRange: NSRange) {
        pendingSlashRange = slashRange
        let menu = NSMenu()
        menu.font = Theme.font(size: 13)
        for (index, command) in Self.slashCommands.enumerated() {
            guard let command else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: command.title, action: #selector(applySlashCommand(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        guard let window else { return }
        let screenRect = firstRect(forCharacterRange: slashRange, actualRange: nil)
        let local = convert(window.convertFromScreen(screenRect), from: nil)
        menu.popUp(positioning: nil, at: NSPoint(x: local.minX, y: local.maxY + 4), in: self)
    }

    @objc private func applySlashCommand(_ sender: NSMenuItem) {
        guard let range = pendingSlashRange,
              let command = Self.slashCommands[sender.tag] else { return }
        pendingSlashRange = nil
        insertText(command.snippet, replacementRange: range)
        if let offset = command.caretOffset {
            setSelectedRange(NSRange(location: range.location + offset, length: 0))
        }
    }

    // MARK: - List continuation

    private static let taskMarker = try! NSRegularExpression(pattern: #"^(\s*)([-*+])[ \t]\[[ xX]\][ \t]"#)
    private static let bulletMarker = try! NSRegularExpression(pattern: #"^(\s*)([-*+])[ \t]"#)
    private static let orderedMarker = try! NSRegularExpression(pattern: #"^(\s*)(\d+)([.)])[ \t]"#)
    private static let quoteMarker = try! NSRegularExpression(pattern: #"^(\s*)>[ \t]?"#)
    private static let anyListMarker = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d+[.)])[ \t]"#)

    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        let ns = string as NSString
        guard sel.length == 0, sel.location <= ns.length else {
            super.insertNewline(sender)
            return
        }
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        var line = ns.substring(with: lineRange)
        if line.hasSuffix("\n") { line.removeLast() }
        let lineNS = line as NSString
        let localRange = NSRange(location: 0, length: lineNS.length)

        var continuation: String?
        var markerLength = 0

        if let m = Self.taskMarker.firstMatch(in: line, range: localRange) {
            markerLength = m.range.length
            continuation = lineNS.substring(with: m.range(at: 1)) + lineNS.substring(with: m.range(at: 2)) + " [ ] "
        } else if let m = Self.bulletMarker.firstMatch(in: line, range: localRange) {
            markerLength = m.range.length
            continuation = lineNS.substring(with: m.range(at: 1)) + lineNS.substring(with: m.range(at: 2)) + " "
        } else if let m = Self.orderedMarker.firstMatch(in: line, range: localRange) {
            markerLength = m.range.length
            let next = (Int(lineNS.substring(with: m.range(at: 2))) ?? 0) + 1
            continuation = lineNS.substring(with: m.range(at: 1)) + "\(next)" + lineNS.substring(with: m.range(at: 3)) + " "
        } else if let m = Self.quoteMarker.firstMatch(in: line, range: localRange) {
            markerLength = m.range.length
            continuation = lineNS.substring(with: m.range(at: 1)) + "> "
        }

        guard let continuation, sel.location - lineRange.location >= markerLength else {
            super.insertNewline(sender)
            return
        }

        let content = lineNS.substring(from: markerLength).trimmingCharacters(in: .whitespaces)
        if content.isEmpty {
            // Empty list item: Enter exits the list by clearing the marker.
            insertText("", replacementRange: NSRange(location: lineRange.location, length: lineNS.length))
        } else {
            insertText("\n" + continuation, replacementRange: sel)
        }
    }

    override func insertTab(_ sender: Any?) {
        guard let lineRange = listLineRange() else {
            super.insertTab(sender)
            return
        }
        insertText("  ", replacementRange: NSRange(location: lineRange.location, length: 0))
    }

    override func insertBacktab(_ sender: Any?) {
        guard let lineRange = listLineRange() else {
            super.insertBacktab(sender)
            return
        }
        let ns = string as NSString
        let line = ns.substring(with: lineRange)
        let removable = line.prefix(2).prefix(while: { $0 == " " }).count
        if removable > 0 {
            insertText("", replacementRange: NSRange(location: lineRange.location, length: removable))
        }
    }

    private func listLineRange() -> NSRange? {
        let sel = selectedRange()
        guard sel.length == 0 else { return nil }
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: lineRange)
        let match = Self.anyListMarker.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        return match != nil ? lineRange : nil
    }

    // MARK: - Inline formatting

    @objc func toggleBoldMD(_ sender: Any?) { toggleInline("**") }
    @objc func toggleItalicMD(_ sender: Any?) { toggleInline("*") }
    @objc func toggleCodeMD(_ sender: Any?) { toggleInline("`") }

    /// Trims surrounding whitespace/newlines out of a range: a triple-clicked
    /// line includes its trailing newline, which would put a closing
    /// delimiter on the next line.
    private func trimmedToContent(_ range: NSRange) -> NSRange {
        let ns = string as NSString
        var sel = range
        let whitespace = CharacterSet.whitespacesAndNewlines
        while sel.length > 0,
              let scalar = Unicode.Scalar(ns.character(at: sel.location)),
              whitespace.contains(scalar) {
            sel.location += 1
            sel.length -= 1
        }
        while sel.length > 0,
              let scalar = Unicode.Scalar(ns.character(at: NSMaxRange(sel) - 1)),
              whitespace.contains(scalar) {
            sel.length -= 1
        }
        return sel
    }

    // MARK: - Text color (serialized as inline HTML spans)

    private static let colorOpenTag = try! NSRegularExpression(
        pattern: #"<span style="color:#([0-9A-Fa-f]{6})">"#)
    private static let colorCloseTag = "</span>"

    /// A single content character with the color of the innermost span that
    /// covers it. Tags themselves are not content, so they never survive a
    /// rewrite — the serializer emits fresh, balanced ones.
    private struct ColoredChar {
        let unit: unichar
        let location: Int
        var hex: String?
    }

    private static func sameHex(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.caseInsensitiveCompare(b) == .orderedSame
        default: return false
        }
    }

    /// Walks `range` tag by tag, returning its content characters tagged with
    /// the color in effect, plus the full range of each outermost span. A
    /// `</span>` with nothing open is treated as content so stray text is
    /// never silently eaten.
    private func colorScan(in range: NSRange) -> (chars: [ColoredChar], spans: [NSRange]) {
        let ns = string as NSString
        let closeLength = (Self.colorCloseTag as NSString).length
        var chars: [ColoredChar] = []
        var spans: [NSRange] = []
        var open: [(hex: String, start: Int)] = []
        var i = range.location
        let end = NSMaxRange(range)
        while i < end {
            let rest = NSRange(location: i, length: end - i)
            if let m = Self.colorOpenTag.firstMatch(in: string, options: .anchored, range: rest) {
                open.append((ns.substring(with: m.range(at: 1)), i))
                i = NSMaxRange(m.range)
                continue
            }
            if !open.isEmpty, i + closeLength <= end,
               ns.substring(with: NSRange(location: i, length: closeLength)) == Self.colorCloseTag {
                let span = open.removeLast()
                if open.isEmpty {
                    spans.append(NSRange(location: span.start, length: i + closeLength - span.start))
                }
                i += closeLength
                continue
            }
            chars.append(ColoredChar(unit: ns.character(at: i), location: i, hex: open.last?.hex))
            i += 1
        }
        return (chars, spans)
    }

    /// Paints the selection `hex`, replacing whatever colors it already
    /// carries; reapplying the color it uniformly carries strips it instead.
    ///
    /// The selection is flattened rather than wrapped: wrapping a mixed or
    /// half-covered stretch of text nests spans inside spans (or splits a
    /// tag down the middle), and the highlighter, which matches one span at
    /// a time, then renders the leftover tags as literal text.
    func applyColor(hex: String) {
        let ns = string as NSString
        let sel = trimmedToContent(selectedRange())
        guard sel.length > 0 else { return }

        // Spans never cross a blank line in practice, so the paragraphs the
        // selection touches are enough context to re-serialize from.
        let (chars, spans) = colorScan(in: ns.paragraphRange(for: sel))

        // Rewrite the selection plus any span it only partly covers, so the
        // uncovered remainder keeps its own color under a tag of its own.
        var start = sel.location
        var end = NSMaxRange(sel)
        for span in spans where NSIntersectionRange(span, sel).length > 0 {
            start = min(start, span.location)
            end = max(end, NSMaxRange(span))
        }
        let region = NSRange(location: start, length: end - start)

        var painted = chars.filter { $0.location >= start && $0.location < end }
        let covered = painted.indices.filter { NSLocationInRange(painted[$0].location, sel) }
        guard !covered.isEmpty else { return }
        let uniform = covered.allSatisfy { Self.sameHex(painted[$0].hex, hex) }
        for i in covered { painted[i].hex = uniform ? nil : hex }

        var units: [unichar] = []
        func emit(_ text: String) { units.append(contentsOf: text.utf16) }
        var current: String?
        var selStart = 0, selEnd = 0
        for (i, c) in painted.enumerated() {
            if !Self.sameHex(c.hex, current) {
                if current != nil { emit(Self.colorCloseTag) }
                if let hex = c.hex { emit("<span style=\"color:#\(hex)\">") }
                current = c.hex
            }
            if i == covered.first { selStart = units.count }
            units.append(c.unit)
            if i == covered.last { selEnd = units.count }
        }
        if current != nil { emit(Self.colorCloseTag) }

        insertText(String(utf16CodeUnits: units, count: units.count), replacementRange: region)
        setSelectedRange(NSRange(location: region.location + selStart, length: selEnd - selStart))
    }

    /// An emphasis span on one line: full range including delimiters, inner
    /// content, and which style layers it carries.
    private struct EmphasisSpan {
        let range: NSRange
        let content: NSRange
        let bold: Bool
        let italic: Bool
    }

    private func emphasisSpans(inLine lineRange: NSRange) -> [EmphasisSpan] {
        let ns = string as NSString
        let line = ns.substring(with: lineRange)
        let local = NSRange(location: 0, length: (line as NSString).length)
        func global(_ r: NSRange) -> NSRange {
            NSRange(location: lineRange.location + r.location, length: r.length)
        }
        var spans: [EmphasisSpan] = []
        MarkdownHighlighter.boldItalicText.enumerateMatches(in: line, range: local) { m, _, _ in
            guard let m else { return }
            spans.append(EmphasisSpan(range: global(m.range), content: global(m.range(at: 2)),
                                      bold: true, italic: true))
        }
        for (regex, isBold) in [(MarkdownHighlighter.boldText, true), (MarkdownHighlighter.italicText, false)] {
            regex.enumerateMatches(in: line, range: local) { m, _, _ in
                guard let m else { return }
                let r = global(m.range)
                guard !spans.contains(where: { $0.bold && $0.italic && NSIntersectionRange($0.range, r).length > 0 }) else { return }
                spans.append(EmphasisSpan(range: r, content: global(m.range(at: 2)),
                                          bold: isBold, italic: !isBold))
            }
        }
        return spans
    }

    /// Layer-aware bold/italic toggling: `*`, `**`, and `***` are treated as
    /// independent style layers on the same text, not opaque characters, so
    /// bolding an italicized word gives `***word***` and toggling one layer
    /// off a combined span leaves the other intact. Returns false when the
    /// selection touches no emphasis span (the caller then wraps naively).
    private func toggleEmphasis(bold: Bool, selection sel: NSRange) -> Bool {
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        guard NSMaxRange(sel) <= NSMaxRange(lineRange) else { return false }
        let spans = emphasisSpans(inLine: lineRange)

        // A span containing the selection: toggle its layer. A zero-length
        // caret must be strictly inside (a caret at the boundary is "next to"
        // the span, not on it). Prefer a span that has the layer being
        // toggled (unwrap beats promote), innermost first.
        let containing = spans.filter { span in
            sel.location >= span.range.location && NSMaxRange(sel) <= NSMaxRange(span.range)
                && (sel.length > 0 || (sel.location > span.range.location && sel.location < NSMaxRange(span.range)))
        }.sorted { $0.range.length < $1.range.length }
        if let span = containing.first(where: { bold ? $0.bold : $0.italic }) ?? containing.first {
            let hasLayer = bold ? span.bold : span.italic
            let content = ns.substring(with: span.content)
            let newDelimiter: String
            if hasLayer {
                // Remove this layer, keeping the other if present.
                newDelimiter = (bold ? span.italic : span.bold) ? (bold ? "*" : "**") : ""
            } else {
                // Adding a layer rewrites the whole span, so only do it when
                // the selection means the whole span; a sub-range selection
                // falls back to wrapping just that range.
                let coversContent = sel.location <= span.content.location
                    && NSMaxRange(sel) >= NSMaxRange(span.content)
                guard sel.length == 0 || coversContent else { return false }
                newDelimiter = "***"
            }
            insertText(newDelimiter + content + newDelimiter, replacementRange: span.range)
            setSelectedRange(NSRange(location: span.range.location + (newDelimiter as NSString).length,
                                     length: (content as NSString).length))
            return true
        }

        // The selection reaches beyond span boundaries: grow it to whole
        // spans, strip this layer from every span inside, and wrap the lot —
        // Word-style "make the whole selection bold".
        let touching = spans.filter { NSIntersectionRange($0.range, sel).length > 0 }
        guard !touching.isEmpty else { return false }
        var grown = sel
        for span in touching { grown = NSUnionRange(grown, span.range) }
        let rebuilt = NSMutableString(string: ns.substring(with: grown))
        let stripped = spans
            .filter { $0.range.location >= grown.location && NSMaxRange($0.range) <= NSMaxRange(grown) }
            .filter { bold ? $0.bold : $0.italic }
        for span in stripped.sorted(by: { $0.range.location > $1.range.location }) {
            let keep = (bold ? span.italic : span.bold) ? (bold ? "*" : "**") : ""
            let local = NSRange(location: span.range.location - grown.location, length: span.range.length)
            rebuilt.replaceCharacters(in: local, with: keep + ns.substring(with: span.content) + keep)
        }
        let delimiter = bold ? "**" : "*"
        insertText(delimiter + (rebuilt as String) + delimiter, replacementRange: grown)
        setSelectedRange(NSRange(location: grown.location + (delimiter as NSString).length,
                                 length: rebuilt.length))
        return true
    }

    private func toggleInline(_ delimiter: String) {
        let ns = string as NSString
        let dLen = (delimiter as NSString).length
        var sel = selectedRange()

        if sel.length == 0 {
            let word = selectionRange(forProposedRange: sel, granularity: .selectByWord)
            let wordText = ns.substring(with: word)
            if !wordText.isEmpty,
               wordText.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
                sel = word
            }
        }

        sel = trimmedToContent(sel)

        if delimiter == "**" || delimiter == "*" {
            if toggleEmphasis(bold: delimiter == "**", selection: sel) { return }
        }

        let selected = ns.substring(with: sel)

        if selected.hasPrefix(delimiter), selected.hasSuffix(delimiter), (selected as NSString).length >= 2 * dLen {
            // Selection includes the delimiters: unwrap.
            let inner = (selected as NSString).substring(with: NSRange(location: dLen, length: (selected as NSString).length - 2 * dLen))
            insertText(inner, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location, length: (inner as NSString).length))
        } else if sel.location >= dLen,
                  NSMaxRange(sel) + dLen <= ns.length,
                  ns.substring(with: NSRange(location: sel.location - dLen, length: dLen)) == delimiter,
                  ns.substring(with: NSRange(location: NSMaxRange(sel), length: dLen)) == delimiter {
            // Delimiters surround the selection: unwrap.
            let outer = NSRange(location: sel.location - dLen, length: sel.length + 2 * dLen)
            insertText(selected, replacementRange: outer)
            setSelectedRange(NSRange(location: outer.location, length: sel.length))
        } else {
            insertText(delimiter + selected + delimiter, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + dLen, length: sel.length))
        }
    }

    @objc func insertLinkMD(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let selected = ns.substring(with: sel)
        insertText("[\(selected)]()", replacementRange: sel)
        if selected.isEmpty {
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
        } else {
            setSelectedRange(NSRange(location: sel.location + sel.length + 3, length: 0))
        }
    }

    @objc func setHeading(_ sender: NSMenuItem) {
        let level = sender.tag
        let ns = string as NSString
        let sel = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: lineRange)
        let existing = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]"#)
        let localRange = NSRange(location: 0, length: (line as NSString).length)

        var stripLength = 0
        var currentLevel = 0
        if let m = existing.firstMatch(in: line, range: localRange) {
            stripLength = m.range.length
            currentLevel = m.range(at: 1).length
        }
        let newPrefix = (level > 0 && level != currentLevel) ? String(repeating: "#", count: level) + " " : ""
        insertText(newPrefix, replacementRange: NSRange(location: lineRange.location, length: stripLength))
    }

    // MARK: - Paste as plain text

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }
}
