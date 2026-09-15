import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    var openRecentMenu: NSMenu!
    private(set) var controllers: [EditorWindowController] = []
    private var settings: SettingsWindowController?

    /// The controller of the key window, else the frontmost one.
    var keyController: EditorWindowController? {
        if let key = NSApp.keyWindow, let c = controllers.first(where: { $0.window === key }) {
            return c
        }
        return controllers.first
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Capture before any window exists: refreshChrome() overwrites the
        // stored session as windows come up.
        let savedWindows = UserDefaults.standard.array(forKey: "sessionWindows") as? [[String: Any]] ?? []
        buildMainMenu()

        let args = Array(CommandLine.arguments.dropFirst())
        var cliFiles: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if arg == "--snapshot" { skipNext = true; continue }
            if arg.hasPrefix("-") { continue }
            cliFiles.append(arg)
        }

        if !cliFiles.isEmpty {
            let controller = makeWindow()
            for path in cliFiles { controller.open(url: URL(fileURLWithPath: path)) }
        } else {
            restoreSession(savedWindows)
            restoreRecoveredDrafts()
            if controllers.isEmpty { makeWindow() }
        }

        NSApp.activate(ignoringOtherApps: true)

        // Debug: select line N fully and bold it, to reproduce artifacts.
        if let flagIndex = args.firstIndex(of: "--boldline"), args.indices.contains(flagIndex + 1),
           let lineNumber = Int(args[flagIndex + 1]), let tv = keyController?.textView {
            let ns = tv.string as NSString
            var lineStart = 0
            for _ in 0..<lineNumber {
                lineStart = NSMaxRange(ns.lineRange(for: NSRange(location: lineStart, length: 0)))
            }
            tv.setSelectedRange(ns.lineRange(for: NSRange(location: lineStart, length: 0)))
            tv.toggleBoldMD(nil)
        }

        if args.contains("--settings") { openSettings(nil) }
        if let flagIndex = args.firstIndex(of: "--snapshot"), args.indices.contains(flagIndex + 1) {
            let outPath = args[flagIndex + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                let targetWindow = args.contains("--settings") ? settings?.window : keyController?.window
                guard let view = targetWindow?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: outPath))
                keyController?.dumpLineFragments(to: outPath + ".layout.txt")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let controller = keyController ?? makeWindow()
        return controller.open(url: URL(fileURLWithPath: filename))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quit never prompts: named documents flush to their files, untitled
        // buffers persist as recovery drafts and reappear next launch. Only
        // if a draft cannot be written do we fall back to save/discard.
        for controller in controllers where !controller.persistAllDrafts() {
            guard controller.resolveAllUnsavedChanges() else { return .terminateCancel }
        }
        if !controllers.isEmpty { sessionChanged() }
        return .terminateNow
    }

    // MARK: - Windows

    private var cascadePoint = NSPoint.zero

    @discardableResult
    func makeWindow(documents: [Document] = [], frame frameString: String? = nil) -> EditorWindowController {
        let controller = EditorWindowController(documents: documents, app: self)
        if let frameString, let window = controller.window {
            var frame = NSRectFromString(frameString)
            if frame.width > 100 {
                if let screen = NSScreen.main {
                    frame = window.constrainFrameRect(frame, to: screen)
                }
                window.setFrame(frame, display: false)
            }
        } else if let window = controller.window {
            // TextEdit-style cascade; AppKit keeps the result on screen.
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
        controllers.append(controller)
        controller.showWindow(nil)
        sessionChanged()
        return controller
    }

    @objc func newWindow(_ sender: Any?) {
        makeWindow()
    }

    func windowClosed(_ controller: EditorWindowController) {
        controllers.removeAll { $0 === controller }
        // Keep the stored session when the last window goes (the app is
        // quitting) so the next launch restores it.
        if !controllers.isEmpty { sessionChanged() }
    }

    /// Detach a tab into its own window at the drop point.
    func detachTab(from source: EditorWindowController, index: Int, to screenPoint: NSPoint) {
        guard let doc = source.removeDocument(at: index) else { return }
        let controller = makeWindow(documents: [doc])
        if let window = controller.window, let sourceFrame = source.window?.frame {
            window.setFrame(sourceFrame, display: false)
            window.setFrameTopLeftPoint(NSPoint(x: screenPoint.x - 60, y: screenPoint.y + 18))
            if let screen = window.screen ?? NSScreen.main {
                window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
            }
        }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Focuses the tab holding `url` in any window, if it is already open.
    func focusExisting(url: URL) -> Bool {
        for controller in controllers where controller.focus(url: url) {
            addRecentFile(url)
            return true
        }
        return false
    }

    // MARK: - Fallbacks when no editor window is key (e.g. settings panel)

    @objc func newTab(_ sender: Any?) {
        if let keyController { keyController.newTab(sender) } else { makeWindow() }
    }

    @objc func closeTab(_ sender: Any?) {
        if let settingsWindow = settings?.window, NSApp.keyWindow === settingsWindow {
            settingsWindow.close()
            return
        }
        keyController?.closeTab(sender)
    }

    @objc func openDocument(_ sender: Any?) {
        (keyController ?? makeWindow()).openDocument(sender)
    }

    // MARK: - Recent files

    private var recentFiles: [String] {
        get { UserDefaults.standard.stringArray(forKey: "recentFiles") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(12)), forKey: "recentFiles") }
    }

    func addRecentFile(_ url: URL) {
        var list = recentFiles.filter { $0 != url.path }
        list.insert(url.path, at: 0)
        recentFiles = list
    }

    func recentFileRenamed(from oldURL: URL, to newURL: URL) {
        recentFiles = recentFiles.filter { $0 != oldURL.path }
        addRecentFile(newURL)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === openRecentMenu else { return }
        menu.removeAllItems()
        let files = recentFiles.filter { FileManager.default.fileExists(atPath: $0) }
        for path in files {
            let item = NSMenuItem(title: (path as NSString).lastPathComponent,
                                  action: #selector(openRecentFile(_:)), keyEquivalent: "")
            item.representedObject = path
            item.toolTip = path
            menu.addItem(item)
        }
        if files.isEmpty {
            let empty = menu.addItem(withTitle: "No Recent Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecentFiles(_:)), keyEquivalent: "")
    }

    @objc private func openRecentFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        (keyController ?? makeWindow()).open(url: URL(fileURLWithPath: path))
    }

    @objc func clearRecentFiles(_ sender: Any?) {
        recentFiles = []
    }

    // MARK: - Session

    func sessionChanged() {
        let entries: [[String: Any]] = controllers.compactMap { controller in
            let files = controller.documents.compactMap { $0.url?.path }
            guard !files.isEmpty, let window = controller.window else { return nil }
            return [
                "files": files,
                "current": controller.currentDocument.url?.path ?? "",
                "frame": NSStringFromRect(window.frame),
            ]
        }
        UserDefaults.standard.set(entries, forKey: "sessionWindows")
    }

    private func restoreSession(_ savedWindows: [[String: Any]]) {
        for entry in savedWindows {
            let files = (entry["files"] as? [String] ?? [])
                .filter { FileManager.default.fileExists(atPath: $0) }
            guard !files.isEmpty else { continue }
            let controller = makeWindow(frame: entry["frame"] as? String)
            for path in files { controller.open(url: URL(fileURLWithPath: path)) }
            if let currentPath = entry["current"] as? String,
               let index = controller.documents.firstIndex(where: { $0.url?.path == currentPath }) {
                controller.switchTab(to: index)
            }
        }
        // Legacy single-window session from earlier builds.
        if controllers.isEmpty {
            let paths = (UserDefaults.standard.stringArray(forKey: "sessionFiles") ?? [])
                .filter { FileManager.default.fileExists(atPath: $0) }
            guard !paths.isEmpty else { return }
            let controller = makeWindow()
            for path in paths { controller.open(url: URL(fileURLWithPath: path)) }
        }
    }

    /// Reopens drafts the previous run left behind (crash, force-quit, or a
    /// quit with untitled buffers). Session restore has already run, so named
    /// files that are open again picked their drafts up in open(url:).
    private func restoreRecoveredDrafts() {
        for entry in RecoveryStore.loadAll() {
            if let path = entry.path {
                let url = URL(fileURLWithPath: path)
                let isOpen = controllers.contains { c in c.documents.contains { $0.url == url } }
                guard !isOpen else { continue }
                if FileManager.default.fileExists(atPath: path) {
                    (keyController ?? makeWindow()).open(url: url)
                } else if !entry.content.isEmpty {
                    // The file vanished; keep the words as an untitled draft.
                    var orphan = entry
                    orphan.path = nil
                    orphan.title = url.deletingPathExtension().lastPathComponent
                    (keyController ?? makeWindow()).adoptRecoveredDraft(orphan)
                } else {
                    RecoveryStore.remove(id: entry.id)
                }
            } else if entry.content.isEmpty {
                RecoveryStore.remove(id: entry.id)
            } else {
                (keyController ?? makeWindow()).adoptRecoveredDraft(entry)
            }
        }
    }

    // MARK: - Settings & font

    @objc func openSettings(_ sender: Any?) {
        if settings == nil {
            settings = SettingsWindowController { [weak self] in self?.applyFontChangeEverywhere() }
        }
        settings?.show()
    }

    private func applyFontChangeEverywhere() {
        controllers.forEach { $0.applyFontChange() }
    }

    @objc func increaseFontSize(_ sender: Any?) { adjustFontSize(by: 2) }
    @objc func decreaseFontSize(_ sender: Any?) { adjustFontSize(by: -2) }

    private func adjustFontSize(by delta: CGFloat) {
        Theme.fontSize = min(max(Theme.fontSize + delta, 10), 64)
        applyFontChangeEverywhere()
    }
}
