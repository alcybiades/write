import AppKit

/// Minimal settings panel with independent document and interface fonts,
/// applied live and persisted.
final class SettingsWindowController: NSObject {

    private(set) var window: NSWindow?
    private let onFontChange: () -> Void
    private var interfaceLabels: [NSTextField] = []
    private var popups: [NSPopUpButton] = []

    init(onFontChange: @escaping () -> Void) {
        self.onFontChange = onFontChange
    }

    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let panel = WriteWindow(
            contentRect: NSRect(x: 0, y: 0, width: 455, height: 185),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.title = "Settings"
        panel.isReleasedWhenClosed = false

        let container = applyTerminalBackdrop(to: panel)

        // Native titlebar controls are hidden, so draw our own × in the
        // corner, mirroring the tab strip's.
        let close = HoverCloseButton()
        close.onClick = { [weak panel] in panel?.close() }
        close.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(close)
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            close.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),
        ])

        let heading = NSTextField(labelWithString: "settings")
        heading.font = Theme.interfaceFont(size: 12)
        heading.textColor = Theme.secondary
        interfaceLabels.append(heading)

        let bodyRow = fontRow(label: "body font", selectedFamily: Theme.fontFamily, tag: 0)
        let interfaceRow = fontRow(label: "interface font", selectedFamily: Theme.interfaceFontFamily, tag: 1)

        let column = NSStackView(views: [heading, bodyRow, interfaceRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 13
        column.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: 34),
            bodyRow.widthAnchor.constraint(equalToConstant: 405),
            interfaceRow.widthAnchor.constraint(equalToConstant: 405),
        ])

        panel.center()
        window = panel
    }

    private func fontRow(label title: String, selectedFamily: String, tag: Int) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = Theme.interfaceFont(size: 13)
        label.textColor = Theme.foreground
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 105).isActive = true
        interfaceLabels.append(label)

        let popup = NSPopUpButton()
        popup.isBordered = false
        popup.font = Theme.interfaceFont(size: 13)
        popup.contentTintColor = Theme.foreground
        popup.target = self
        popup.action = #selector(fontSelected(_:))
        popup.tag = tag
        // Items are added with nil actions; without this, menu validation
        // can disable them all, making the font list unselectable.
        popup.autoenablesItems = false
        let families = NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for family in families {
            let item = NSMenuItem(title: family, action: nil, keyEquivalent: "")
            item.isEnabled = true
            if let previewFont = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) {
                item.attributedTitle = NSAttributedString(string: family, attributes: [
                    .font: previewFont,
                    .foregroundColor: NSColor.labelColor,
                ])
            }
            popup.menu?.addItem(item)
        }
        popup.selectItem(withTitle: selectedFamily)
        if popup.selectedItem == nil { popup.selectItem(withTitle: Theme.defaultFontFamily) }
        popups.append(popup)

        // A subtle pill behind the borderless popup, echoing the tab style.
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        pill.layer?.cornerRadius = 5
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.widthAnchor.constraint(equalToConstant: 288).isActive = true
        popup.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            popup.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            popup.topAnchor.constraint(equalTo: pill.topAnchor, constant: 4),
            popup.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4),
        ])

        let row = NSStackView(views: [label, pill])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    @objc private func fontSelected(_ sender: NSPopUpButton) {
        guard let family = sender.titleOfSelectedItem else { return }
        if sender.tag == 0 {
            Theme.fontFamily = family
        } else {
            Theme.interfaceFontFamily = family
            interfaceLabels.enumerated().forEach { index, label in
                label.font = Theme.interfaceFont(size: index == 0 ? 12 : 13)
            }
            popups.forEach { $0.font = Theme.interfaceFont(size: 13) }
        }
        onFontChange()
    }
}
