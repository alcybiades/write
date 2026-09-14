import AppKit

/// Minimal settings panel with the same terminal backdrop as the editor:
/// a single font-family dropdown, applied live and persisted.
final class SettingsWindowController: NSObject {

    private(set) var window: NSWindow?
    private let onFontChange: () -> Void

    init(onFontChange: @escaping () -> Void) {
        self.onFontChange = onFontChange
    }

    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let panel = BorderlessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 130),
            styleMask: [.borderless, .closable],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.title = "Settings"
        panel.isReleasedWhenClosed = false

        let container = applyTerminalBackdrop(to: panel)

        let heading = NSTextField(labelWithString: "settings")
        heading.font = Theme.font(size: 12)
        heading.textColor = Theme.dim

        let fontLabel = NSTextField(labelWithString: "font")
        fontLabel.font = Theme.font(size: 13)
        fontLabel.textColor = Theme.foreground

        let popup = NSPopUpButton()
        popup.isBordered = false
        popup.font = Theme.font(size: 13)
        popup.contentTintColor = Theme.foreground
        popup.target = self
        popup.action = #selector(fontSelected(_:))
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
        popup.selectItem(withTitle: Theme.fontFamily)
        if popup.selectedItem == nil { popup.selectItem(withTitle: Theme.defaultFontFamily) }

        // A subtle pill behind the borderless popup, echoing the tab style.
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        pill.layer?.cornerRadius = 5
        popup.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            popup.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            popup.topAnchor.constraint(equalTo: pill.topAnchor, constant: 4),
            popup.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4),
        ])

        let fontRow = NSStackView(views: [fontLabel, pill])
        fontRow.orientation = .horizontal
        fontRow.spacing = 12

        let column = NSStackView(views: [heading, fontRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: 34),
            pill.widthAnchor.constraint(equalToConstant: 280),
        ])

        panel.center()
        window = panel
    }

    @objc private func fontSelected(_ sender: NSPopUpButton) {
        guard let family = sender.titleOfSelectedItem else { return }
        Theme.fontFamily = family
        onFontChange()
    }
}
