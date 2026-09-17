import AppKit

/// Minimal terminal-styled tab strip with hover-close and drag-to-detach.
final class TabBarView: NSView {

    /// Equal gap from the window's top-left corner to the first tab, both
    /// axes. The pill radius is windowCornerRadius − cornerPadding so the
    /// tab's arc is concentric with the window's arc.
    static let cornerPadding: CGFloat = 15
    static var pillRadius: CGFloat { Theme.windowCornerRadius - cornerPadding }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    /// Fired when a tab is dragged out of the bar; point is in screen coords.
    var onDetach: ((Int, NSPoint) -> Void)?

    var onToggleSidebar: (() -> Void)?
    var onMediaMode: ((Bool) -> Void)?
    private let controls = NSView()
    private let toggle = SidebarIconButton()
    private let files = SidebarIconButton()
    private let media = SidebarIconButton()
    private var controlsWidth: NSLayoutConstraint!
    private let stack = NSStackView()
    private let tabScroll = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: Self.cornerPadding)
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = true
        tabScroll.autohidesScrollers = true
        tabScroll.scrollerStyle = .overlay
        tabScroll.documentView = stack
        tabScroll.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        addSubview(tabScroll)
        for (button, symbol, label, action) in [
            (toggle, "sidebar.left", "Toggle sidebar", #selector(toggleSidebar)),
            (files, "doc", "Files", #selector(selectFiles)),
            (media, "photo", "Media", #selector(selectMedia))
        ] {
            button.symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.title = ""
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.target = self; button.action = action
            button.wantsLayer = true; button.layer?.cornerRadius = 7
            controls.addSubview(button)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 30), button.heightAnchor.constraint(equalToConstant: 31),
                button.centerYAnchor.constraint(equalTo: tabScroll.centerYAnchor),
            ])
        }
        controlsWidth = controls.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor), controls.topAnchor.constraint(equalTo: topAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor), controlsWidth,
            tabScroll.leadingAnchor.constraint(equalTo: controls.trailingAnchor, constant: Self.cornerPadding),
            tabScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabScroll.topAnchor.constraint(equalTo: topAnchor, constant: Self.cornerPadding),
            tabScroll.heightAnchor.constraint(equalToConstant: 31),
            toggle.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: Self.cornerPadding),
            files.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 55),
            media.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 93),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configureSidebar(visible: Bool, collapsed: Bool, width: CGFloat, mediaMode: Bool) {
        controlsWidth.constant = visible ? (collapsed ? 45 : width) : 0
        controls.isHidden = !visible
        files.isHidden = collapsed; media.isHidden = collapsed
        files.contentTintColor = mediaMode ? Theme.dim : Theme.foreground
        media.contentTintColor = mediaMode ? Theme.foreground : Theme.dim
        toggle.contentTintColor = Theme.dim
        toggle.toolTip = collapsed ? "Expand sidebar" : "Collapse sidebar"
        toggle.setAccessibilityLabel(toggle.toolTip)
        toggle.chevronName = collapsed ? "chevron.right" : "chevron.left"
        [toggle, files, media].forEach { $0.needsDisplay = true }
        files.layer?.backgroundColor = NSColor.white.withAlphaComponent(mediaMode ? 0 : 0.08).cgColor
        media.layer?.backgroundColor = NSColor.white.withAlphaComponent(mediaMode ? 0.08 : 0).cgColor
    }
    @objc private func toggleSidebar() { onToggleSidebar?() }
    @objc private func selectFiles() { onMediaMode?(false) }
    @objc private func selectMedia() { onMediaMode?(true) }

    func update(tabs: [(name: String, edited: Bool)], selected: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let item = TabItemView(
                title: tab.edited ? "\(tab.name) •" : tab.name,
                active: index == selected
            )
            item.onClick = { [weak self] in self?.onSelect?(index) }
            item.onClose = { [weak self] in self?.onClose?(index) }
            item.onDetach = { [weak self] screenPoint in self?.onDetach?(index, screenPoint) }
            stack.addArrangedSubview(item)
        }
        let plus = NewTabButton()
        plus.onClick = { [weak self] in self?.onNewTab?() }
        stack.addArrangedSubview(plus)
        stack.setFrameSize(NSSize(width: stack.fittingSize.width, height: 31))
        layoutSubtreeIfNeeded()
        if stack.arrangedSubviews.indices.contains(selected) {
            let selectedTab = stack.arrangedSubviews[selected]
            selectedTab.scrollToVisible(selectedTab.bounds)
        }
    }
}

/// The [+] at the end of the tab strip.
private final class NewTabButton: NSView {

    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = TabBarView.pillRadius
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 31),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        drawGlyphCentered("+", size: 22, color: hovered ? Theme.foreground : Theme.dim, in: bounds)
    }
}

/// Draws a glyph so its actual ink (not its layout box, which includes
/// ascent/descent whitespace) is centered in `rect`. The ink bounds come
/// from the font's glyph metrics, relative to the baseline; draw(at:) puts
/// the line box origin (baseline minus descent) at the given point.
private func drawGlyphCentered(_ string: String, size: CGFloat, color: NSColor, in rect: NSRect) {
    let font = Theme.font(size: size)
    let text = NSAttributedString(string: string, attributes: [
        .font: font,
        .foregroundColor: color,
    ])
    var chars = Array(string.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count) else {
        text.draw(at: NSPoint(x: rect.midX - text.size().width / 2,
                              y: rect.midY - text.size().height / 2))
        return
    }
    let ink = CTFontGetBoundingRectsForGlyphs(font, .default, glyphs, nil, glyphs.count)
    text.draw(at: NSPoint(
        x: rect.midX - ink.midX,
        y: rect.midY - ink.midY + font.descender
    ))
}

private final class TabItemView: NSView {

    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onDetach: ((NSPoint) -> Void)?

    private let title: String
    private let label: NSTextField
    private let closeButton = HoverCloseButton()

    // Normally the text fills the tab edge-to-edge; on hover the × overlays
    // the trailing end and the label truncates into the remaining space.
    private var labelTrailingNormal: NSLayoutConstraint!
    private var labelTrailingHover: NSLayoutConstraint!
    private var frozenWidth: NSLayoutConstraint?

    private var ghost: NSWindow?

    init(title: String, active: Bool) {
        self.title = title
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = TabBarView.pillRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = active
            ? NSColor.white.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor

        label.font = Theme.font(size: 13.5)
        label.textColor = active ? Theme.foreground : Theme.dim
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.isHidden = true
        closeButton.onClick = { [weak self] in self?.onClose?() }
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        labelTrailingNormal = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13)
        labelTrailingHover = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 31),
            labelTrailingNormal,
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Route every click to the tab itself (the label subview would
    /// otherwise claim hits and let the window-move machinery take the
    /// drag, since non-opaque views default mouseDownCanMoveWindow=true).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !closeButton.isHidden, closeButton.frame.contains(local) { return closeButton }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        // Freeze the tab's width, then let the × overlay the trailing end
        // while the label truncates into the remaining space.
        let freeze = widthAnchor.constraint(equalToConstant: bounds.width)
        freeze.isActive = true
        frozenWidth = freeze
        labelTrailingNormal.isActive = false
        labelTrailingHover.isActive = true
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        labelTrailingHover.isActive = false
        labelTrailingNormal.isActive = true
        frozenWidth?.isActive = false
        frozenWidth = nil
    }

    // MARK: - Click / drag-to-detach

    // Selecting the tab rebuilds the tab bar, which removes this view from
    // the hierarchy mid-gesture — so ordinary mouseDragged/mouseUp dispatch
    // never reaches it. Track the drag with a synchronous event loop
    // instead, which keeps working after the rebuild.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // The tab bar strip in window coordinates, before self is rebuilt.
        let barOnScreen: NSRect
        if let bar = enclosingTabBar() {
            barOnScreen = window.convertToScreen(bar.convert(bar.bounds, to: nil))
        } else {
            barOnScreen = .zero
        }

        onClick?()

        let origin = event.locationInWindow
        var detachPoint: NSPoint?
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            let point = next.locationInWindow
            if next.type == .leftMouseUp {
                if ghost != nil {
                    let screenPoint = window.convertPoint(toScreen: point)
                    if !barOnScreen.insetBy(dx: -24, dy: -24).contains(screenPoint) {
                        detachPoint = screenPoint
                    }
                }
                break
            }
            if ghost == nil, hypot(point.x - origin.x, point.y - origin.y) > 12 {
                makeGhost()
            }
            if let ghost {
                let screenPoint = window.convertPoint(toScreen: point)
                ghost.setFrameOrigin(NSPoint(x: screenPoint.x - ghost.frame.width / 2,
                                             y: screenPoint.y - ghost.frame.height / 2))
            }
        }
        ghost?.close()
        ghost = nil
        if let detachPoint { onDetach?(detachPoint) }
    }

    private func enclosingTabBar() -> NSView? {
        var view: NSView? = superview
        while view != nil, !(view is TabBarView) { view = view?.superview }
        return view
    }

    /// A floating pill following the cursor while dragging, like browsers.
    private func makeGhost() {
        let ghostLabel = NSTextField(labelWithString: title)
        ghostLabel.font = Theme.font(size: 13.5)
        ghostLabel.textColor = Theme.foreground
        let size = ghostLabel.intrinsicContentSize
        let frame = NSRect(x: 0, y: 0, width: size.width + 24, height: size.height + 10)

        let panel = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let content = NSView(frame: frame)
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.background.withAlphaComponent(0.85).cgColor
        content.layer?.cornerRadius = 6
        ghostLabel.frame = NSRect(x: 12, y: 5, width: size.width, height: size.height)
        content.addSubview(ghostLabel)
        panel.contentView = content
        panel.orderFront(nil)
        ghost = panel
    }
}

/// A small "×" that swallows its own clicks so they don't select the tab.
/// Also the settings panel's close affordance — it is borderless, so it has
/// no titlebar widget of its own.
final class HoverCloseButton: NSView {

    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        drawGlyphCentered("×", size: 22, color: hovered ? Theme.foreground : Theme.dim, in: bounds)
    }
}

/// Draw symbols directly, like the other tab controls, without AppKit's bezel.
private final class SidebarIconButton: NSButton {
    var symbolImage: NSImage?
    var chevronName: String?
    override func draw(_ dirtyRect: NSRect) {
        guard let symbolImage else { return }
        let image = symbolImage.withSymbolConfiguration(.init(paletteColors: [contentTintColor ?? Theme.dim])) ?? symbolImage
        let scale = min(16 / image.size.width, 16 / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        if let chevronName, let chevron = NSImage(systemSymbolName: chevronName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [contentTintColor ?? Theme.dim])) {
            chevron.draw(in: NSRect(x: bounds.midX + 1, y: bounds.midY - 3, width: 3, height: 6))
        }
    }
}
