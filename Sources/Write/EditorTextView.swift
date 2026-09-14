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

    private static let fullColorSpan = try! NSRegularExpression(
        pattern: #"^<span style="color:#([0-9A-Fa-f]{6})">(.*)</span>$"#,
        options: [.dotMatchesLineSeparators])
    private static let trailingOpenTag = try! NSRegularExpression(
        pattern: #"<span style="color:#([0-9A-Fa-f]{6})">$"#)

    /// Wraps the selection in a color span; reapplying the same color
    /// removes it, a different color replaces it.
    func applyColor(hex: String) {
        let ns = string as NSString
        let sel = trimmedToContent(selectedRange())
        guard sel.length > 0 else { return }
        let selected = ns.substring(with: sel)
        let selNS = selected as NSString
        let openTag = "<span style=\"color:#\(hex)\">"
        let closeLen = ("</span>" as NSString).length

        // Selection includes the tags: swap the color or unwrap.
        if let m = Self.fullColorSpan.firstMatch(in: selected, range: NSRange(location: 0, length: selNS.length)) {
            let currentHex = selNS.substring(with: m.range(at: 1))
            let inner = selNS.substring(with: m.range(at: 2))
            let replacement = currentHex.caseInsensitiveCompare(hex) == .orderedSame
                ? inner
                : "<span style=\"color:#\(hex)\">\(inner)</span>"
            insertText(replacement, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location, length: (replacement as NSString).length))
            return
        }

        // Selection is the inner text of a surrounding span.
        let lookbackLength = min(40, sel.location)
        let before = ns.substring(with: NSRange(location: sel.location - lookbackLength, length: lookbackLength))
        if let m = Self.trailingOpenTag.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)),
           NSMaxRange(sel) + closeLen <= ns.length,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: closeLen)) == "</span>" {
            let tagLength = m.range.length
            let currentHex = (before as NSString).substring(with: m.range(at: 1))
            let outer = NSRange(location: sel.location - tagLength, length: tagLength + sel.length + closeLen)
            if currentHex.caseInsensitiveCompare(hex) == .orderedSame {
                insertText(selected, replacementRange: outer)
                setSelectedRange(NSRange(location: outer.location, length: sel.length))
            } else {
                insertText(openTag + selected + "</span>", replacementRange: outer)
                setSelectedRange(NSRange(location: outer.location + (openTag as NSString).length, length: sel.length))
            }
            return
        }

        insertText(openTag + selected + "</span>", replacementRange: sel)
        setSelectedRange(NSRange(location: sel.location + (openTag as NSString).length, length: sel.length))
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
