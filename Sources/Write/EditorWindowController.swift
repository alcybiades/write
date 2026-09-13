import AppKit

/// One editor window: its own tab set, text view, inline title, status line,
/// and autosave. Menu actions reach the key window's controller through the
/// responder chain.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {

    private(set) var documents: [Document]
    private(set) var current = 0
    var currentDocument: Document { documents[current] }

    private weak var app: AppDelegate?

    private(set) var textView: EditorTextView!
    private var scrollView: NSScrollView!
    private var tabBar: TabBarView!
    private var statusLabel: NSTextField!
    // The inline title is an always-editable NSTextView: one view for both
    // reading and editing means the glyphs cannot shift when editing starts
    // (NSTextField swaps in a field editor with subtly different metrics).
    private var titleView: NSTextView!
    private var titleReverting = false
    private let titleUndoManager = UndoManager()
    private static let metricsLayoutManager = NSLayoutManager()
    private var selectionToolbar: SelectionToolbar!
    private var autosaveTimer: Timer?
    private var savedFlashTimer: Timer?

    init(documents: [Document] = [], app: AppDelegate?) {
        self.documents = documents.isEmpty ? [Document()] : documents
        self.app = app
        let window = BorderlessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
            styleMask: [.borderless, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 420, height: 320)
        window.collectionBehavior = [.fullScreenPrimary]
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI

    private func buildUI() {
        guard let window else { return }
        let container = applyTerminalBackdrop(to: window)

        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        documents[0].storage.addLayoutManager(layoutManager)

        textView = EditorTextView(frame: .zero, textContainer: textContainer)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.configure()
        textView.delegate = self
        selectionToolbar = SelectionToolbar(textView: textView)

        titleView = NSTextView(frame: .zero)
        titleView.drawsBackground = false
        titleView.isRichText = false
        titleView.allowsUndo = true
        titleView.isVerticallyResizable = false
        titleView.isHorizontallyResizable = false
        titleView.textContainerInset = .zero
        titleView.textContainer?.lineFragmentPadding = 0
        // Single visual line: a huge fixed container width, clipped by frame.
        titleView.textContainer?.widthTracksTextView = false
        titleView.textContainer?.size = NSSize(width: 10000, height: 10000)
        titleView.textColor = NSColor.white.withAlphaComponent(0.5)
        titleView.insertionPointColor = Theme.cursor
        titleView.selectedTextAttributes = [
            .backgroundColor: Theme.selection,
            .foregroundColor: NSColor(hex: 0xF8FAFC),
        ]
        titleView.delegate = self
        textView.addSubview(titleView)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller?.knobStyle = .light
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tabBar = TabBarView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] index in self?.switchTab(to: index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onNewTab = { [weak self] in self?.newTab(nil) }
        tabBar.onDetach = { [weak self] index, screenPoint in
            guard let self else { return }
            app?.detachTab(from: self, index: index, to: screenPoint)
        }

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = Theme.font(size: 11)
        statusLabel.textColor = Theme.dim.withAlphaComponent(0.8)
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(tabBar)
        container.addSubview(scrollView)
        container.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.cornerPadding + 31 + 8),
            scrollView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -26),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(viewResized),
            name: NSView.frameDidChangeNotification, object: scrollView)
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewResized),
            name: NSView.frameDidChangeNotification, object: textView)
        textView.postsFrameChangedNotifications = true
        // Keep the selection toolbar tracking the text as it scrolls.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        // Upper-center placement, like TextEdit/Notes opening a document.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + (visible.height - size.height) * 0.66
            ))
        } else {
            window.center()
        }
        textView.rehighlight()
        let length = (currentDocument.storage.string as NSString).length
        textView.setSelectedRange(NSIntersectionRange(currentDocument.selection, NSRange(location: 0, length: length)))
        updateInsets()
        refreshChrome()
        window.makeFirstResponder(textView)
    }

    func windowWillClose(_ notification: Notification) {
        autosaveTimer?.invalidate()
        savedFlashTimer?.invalidate()
        selectionToolbar.teardown()
        NotificationCenter.default.removeObserver(self)
        app?.windowClosed(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        selectionToolbar.hide()
    }

    @objc private func viewResized() {
        updateInsets()
    }

    @objc private func scrolled() {
        selectionToolbar.noteSelectionChanged()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard (notification.object as? NSTextView) === textView else { return }
        selectionToolbar.noteSelectionChanged()
    }

    private func updateInsets() {
        let titleFont = Theme.boldFont(size: Theme.fontSize * 1.5).font
        let titleHeight = ceil(titleFont.ascender - titleFont.descender) + 6
        // Symmetric breathing room: the gap above the title (below the tab
        // bar) equals the gap between the title and the body text.
        let titleGap = Theme.fontSize * 0.9
        let titleTop = titleGap
        let extraTop = (titleTop - Theme.padding) + titleHeight + titleGap

        let available = textView.bounds.width
        let horizontal = max(Theme.padding, (available - Theme.maxTextWidth) / 2)
        let newInset = NSSize(width: horizontal, height: Theme.padding + extraTop / 2)
        textView.extraTopInset = extraTop
        // Only write when changed: setting the inset resizes the text view,
        // which re-posts the frame notification that got us here.
        if textView.textContainerInset != newInset {
            textView.textContainerInset = newInset
        }

        titleView.font = titleFont
        // NSTextView can seat the first baseline lower than static text
        // drawing does (e.g. Hoefler: 31pt from fragment top vs a 23.8pt
        // ascender). Raise the frame by that difference so the title sits
        // where the ascender-based layout puts it.
        let baselineDelta = max(0, Self.metricsLayoutManager.defaultBaselineOffset(for: titleFont) - titleFont.ascender)
        titleView.frame = NSRect(
            x: horizontal + 5,
            y: titleTop - baselineDelta,
            width: max(120, available - 2 * horizontal - 10),
            height: titleHeight + baselineDelta + 4
        )
    }

    func applyFontChange() {
        textView.rehighlight()
        statusLabel.font = Theme.font(size: 11)
        updateInsets()
        refreshChrome()
    }

    // MARK: - Tabs

    func switchTab(to index: Int) {
        guard documents.indices.contains(index) else { return }
        commitTitleIfEditing()
        flushAutosave()
        currentDocument.selection = textView.selectedRange()
        current = index
        let doc = currentDocument
        textView.layoutManager?.replaceTextStorage(doc.storage)
        textView.rehighlight()
        let length = (doc.storage.string as NSString).length
        let sel = NSIntersectionRange(doc.selection, NSRange(location: 0, length: length))
        textView.setSelectedRange(sel.location <= length ? sel : NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        refreshChrome()
        window?.makeFirstResponder(textView)
    }

    @objc func newTab(_ sender: Any?) {
        documents.append(Document())
        switchTab(to: documents.count - 1)
    }

    @objc func closeTab(_ sender: Any?) {
        closeTab(at: current)
    }

    func closeTab(at index: Int) {
        commitTitleIfEditing()
        guard documents.indices.contains(index), resolveUnsavedChanges(at: index) else { return }
        if documents.count == 1 {
            window?.performClose(nil)
            return
        }
        flushAutosave()
        // resolveUnsavedChanges may have switched `current` onto `index`.
        documents.remove(at: index)
        if current > index { current -= 1 }
        current = min(current, documents.count - 1)
        reattachCurrent()
    }

    /// Removes a tab intact (storage, undo, selection) for detaching into
    /// another window. Returns nil when this is the only tab.
    func removeDocument(at index: Int) -> Document? {
        guard documents.count > 1, documents.indices.contains(index) else { return nil }
        commitTitleIfEditing()
        flushAutosave()
        let doc = documents.remove(at: index)
        if current > index {
            current -= 1
        } else if current >= documents.count {
            current = documents.count - 1
        }
        reattachCurrent()
        return doc
    }

    private func reattachCurrent() {
        textView.layoutManager?.replaceTextStorage(currentDocument.storage)
        textView.rehighlight()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        refreshChrome()
        window?.makeFirstResponder(textView)
    }

    @objc func nextTab(_ sender: Any?) {
        switchTab(to: (current + 1) % documents.count)
    }

    @objc func previousTab(_ sender: Any?) {
        switchTab(to: (current - 1 + documents.count) % documents.count)
    }

    private func refreshChrome() {
        tabBar.update(tabs: documents.map { ($0.name, $0.edited) }, selected: current)
        updateStatus()
        app?.sessionChanged()
    }

    // MARK: - Text changes → autosave + status

    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === textView else { return }
        currentDocument.edited = true
        window?.isDocumentEdited = true
        refreshChrome()
        scheduleAutosave()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        view === titleView ? titleUndoManager : currentDocument.undoManager
    }

    private func scheduleAutosave() {
        guard currentDocument.url != nil else { return }
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            self?.saveCurrentDocument()
        }
    }

    private func flushAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        if documents.indices.contains(current), currentDocument.url != nil, currentDocument.edited {
            saveCurrentDocument()
        }
    }

    private func updateStatus() {
        let words = currentDocument.storage.string
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        statusLabel.stringValue = "\(currentDocument.name) · \(words)w"
        window?.title = currentDocument.name
        if window?.firstResponder !== titleView {
            titleView.string = currentDocument.displayTitle
        }
    }

    // MARK: - Inline title → file rename

    private func commitTitleIfEditing() {
        guard window?.firstResponder === titleView else { return }
        window?.makeFirstResponder(textView)  // textDidEndEditing commits
    }

    func textDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextView) === titleView else { return }
        if titleReverting {
            titleReverting = false
        } else {
            applyTitle(titleView.string)
        }
        titleView.string = currentDocument.displayTitle
    }

    func textView(_ view: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard view === titleView else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            window?.makeFirstResponder(textView)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            titleReverting = true
            window?.makeFirstResponder(textView)
            return true
        default:
            return false
        }
    }

    private func applyTitle(_ rawTitle: String) {
        let doc = currentDocument
        let title = rawTitle
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !title.contains("/"), title != doc.displayTitle else {
            titleView.string = doc.displayTitle
            return
        }
        guard let url = doc.url else {
            doc.customTitle = title
            refreshChrome()
            return
        }
        flushAutosave()
        let newURL = url.deletingLastPathComponent()
            .appendingPathComponent(title)
            .appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            doc.url = newURL
            app?.recentFileRenamed(from: url, to: newURL)
        } catch {
            NSSound.beep()
            titleView.string = doc.displayTitle
        }
        refreshChrome()
    }

    // MARK: - File operations

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!, .plainText]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    @discardableResult
    func open(url: URL) -> Bool {
        // If any window already has it, focus that tab instead.
        if let app, app.focusExisting(url: url) { return true }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            NSSound.beep()
            return false
        }
        app?.addRecentFile(url)
        let doc = Document(url: url, content: content)
        // Reuse the current tab when it's an empty, untouched untitled buffer.
        if currentDocument.url == nil, !currentDocument.edited, currentDocument.storage.length == 0 {
            documents[current] = doc
            switchTab(to: current)
        } else {
            documents.append(doc)
            switchTab(to: documents.count - 1)
        }
        return true
    }

    func focus(url: URL) -> Bool {
        guard let index = documents.firstIndex(where: { $0.url == url }) else { return false }
        switchTab(to: index)
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    @objc func saveDocument(_ sender: Any?) {
        if currentDocument.url == nil {
            promptForSaveURL()
        }
        if saveCurrentDocument() { flashSaved() }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        promptForSaveURL()
        if saveCurrentDocument() { flashSaved() }
    }

    /// Briefly appends "saved" to the status line after a manual save.
    private func flashSaved() {
        statusLabel.stringValue = "\(currentDocument.name) · saved"
        statusLabel.textColor = Theme.code.withAlphaComponent(0.9)
        savedFlashTimer?.invalidate()
        savedFlashTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            statusLabel.textColor = Theme.dim.withAlphaComponent(0.8)
            updateStatus()
        }
    }

    private func promptForSaveURL() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = currentDocument.url?.lastPathComponent
            ?? currentDocument.customTitle.map { $0 + ".md" }
            ?? "untitled.md"
        if panel.runModal() == .OK, let url = panel.url {
            currentDocument.url = url
            app?.addRecentFile(url)
        }
    }

    @discardableResult
    private func saveCurrentDocument() -> Bool {
        let doc = currentDocument
        guard let url = doc.url else { return false }
        do {
            try doc.storage.string.write(to: url, atomically: true, encoding: .utf8)
            doc.edited = false
            window?.isDocumentEdited = false
            refreshChrome()
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    /// Returns true when it is safe to discard the document at `index`.
    private func resolveUnsavedChanges(at index: Int) -> Bool {
        flushAutosave()
        let doc = documents[index]
        guard doc.url == nil, doc.edited, doc.storage.length > 0 else { return true }
        if index != current { switchTab(to: index) }
        window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Save changes to \(doc.displayTitle)?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            promptForSaveURL()
            guard currentDocument.url != nil else { return false }
            saveCurrentDocument()
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func resolveAllUnsavedChanges() -> Bool {
        for index in documents.indices {
            if !resolveUnsavedChanges(at: index) { return false }
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        commitTitleIfEditing()
        return resolveAllUnsavedChanges()
    }

    // MARK: - Debug

    func dumpLineFragments(to path: String) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let ns = currentDocument.storage.string as NSString
        var out = "inset=\(textView.textContainerInset) viewWidth=\(textView.bounds.width) maxTextWidth=\(Theme.maxTextWidth)\n"
        var glyphIndex = 0
        var prevMaxY: CGFloat = 0
        while glyphIndex < lm.numberOfGlyphs {
            var effRange = NSRange()
            let rect = lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &effRange)
            let charRange = lm.characterRange(forGlyphRange: effRange, actualGlyphRange: nil)
            var text = ns.substring(with: charRange).replacingOccurrences(of: "\n", with: "\\n")
            if text.count > 40 { text = String(text.prefix(40)) }
            out += String(format: "y=%6.1f h=%5.1f gap=%5.1f  %@\n", rect.minY, rect.height, rect.minY - prevMaxY, text)
            prevMaxY = rect.maxY
            glyphIndex = NSMaxRange(effRange)
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
