import AppKit

final class FolderSidebar: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onRefresh: (() -> Void)?
    var onOpen: ((URL, Bool) -> Void)?
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private var root: FileNode?
    var mediaMode = false { didSet { reload() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("files"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 25
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = 13
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        addSubview(scroll)
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh Folder", action: #selector(refresh), keyEquivalent: "").target = self
        outline.menu = menu
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        scroll.frame = bounds.width < 12 ? .zero : NSRect(x: 6, y: 8, width: bounds.width - 12, height: max(0, bounds.height - 16))
    }
    func setRoot(_ url: URL) {
        let expanded = Set((0..<outline.numberOfRows).compactMap { row -> String? in
            guard let node = outline.item(atRow: row) as? FileNode, outline.isItemExpanded(node) else { return nil }
            return node.url.path
        })
        root = FileNode(url); reload()
        var row = 0
        while row < outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, expanded.contains(node.url.path) { outline.expandItem(node) }
            row += 1
        }
    }
    @objc func refresh() { if let url = root?.url { setRoot(url); onRefresh?() } }
    private func reload() {
        outline.reloadData()
        if let root { outline.expandItem(root) }
    }
    private func children(_ item: Any?) -> [FileNode] {
        guard let node = item as? FileNode else { return root.map { [$0] } ?? [] }
        return node.children.filter { !mediaMode || $0.isDirectory }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(item).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(item)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.isDirectory == true }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: node.isDirectory ? "folder" : (FileKind.classify(node.url) == .image ? "photo" : "doc"), accessibilityDescription: nil)
        icon.contentTintColor = node.isDirectory ? Theme.heading : Theme.dim
        let label = NSTextField(labelWithString: node.url.lastPathComponent)
        label.font = Theme.font(size: 13.5)
        label.textColor = Theme.foreground.withAlphaComponent(0.85)
        label.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(icon); cell.addSubview(label)
        icon.translatesAutoresizingMaskIntoConstraints = false; label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15), icon.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.textField = label; cell.imageView = icon; cell.toolTip = node.url.path
        return cell
    }
    @objc private func clicked() {
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory && !mediaMode {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else { onOpen?(node.url, node.isDirectory) }
    }
}

final class SidebarDivider: NSView {
    var onResize: ((CGFloat) -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height).fill()
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            onResize?(next.locationInWindow.x)
        }
    }
}
