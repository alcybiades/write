import AppKit

_ = NSApplication.shared
var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("write-workspace-\(UUID().uuidString)")
let root = fixture.appendingPathComponent("Studio")
try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes/Nested"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: root.appendingPathComponent("Media"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: fixture) }
let source = root.appendingPathComponent("Notes/Start.md")
let target = root.appendingPathComponent("Notes/Nested/Design [v2] #1 (final).md")
let imageURL = root.appendingPathComponent("Media/Landscape.png")
let unknown = root.appendingPathComponent("archive.bin")
try "# Start\n\nOpen @ references to connect your notes.\n".write(to: source, atomically: true, encoding: .utf8)
try "# Design\n".write(to: target, atomically: true, encoding: .utf8)
try Data([0, 255, 20, 19]).write(to: unknown)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 320, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 640, height: 320).fill()
NSColor.systemTeal.setFill(); NSBezierPath(ovalIn: NSRect(x: 120, y: 60, width: 240, height: 240)).fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
for n in 1...8 { try FileManager.default.copyItem(at: imageURL, to: root.appendingPathComponent("Media/Study \(n).png")) }

let characters = root.appendingPathComponent("Media/Characters")
let concepts = root.appendingPathComponent("Media/Characters/Concepts")
try FileManager.default.createDirectory(at: concepts, withIntermediateDirectories: true)
try FileManager.default.copyItem(at: imageURL, to: characters.appendingPathComponent("Portrait.png"))
try FileManager.default.copyItem(at: imageURL, to: concepts.appendingPathComponent("Sketch.png"))
try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Media/Loop"), withDestinationURL: root)
let groups = try MediaGallery.sections(in: root)
check("parent galleries include descendant images", groups.reduce(0) { $0 + $1.images.count } == 11)
check("gallery groups are sorted by containing directory", groups.map { FileReference.relativePath(to: $0.directory, from: root) } == ["Media", "Media/Characters", "Media/Characters/Concepts"])
check("breadcrumb ancestors reach workspace root", MediaGallery.breadcrumbs(to: concepts.appendingPathComponent("Sketch.png"), root: root).map(\.lastPathComponent) == ["Studio", "Media", "Characters", "Concepts", "Sketch.png"])
check("outside-workspace images use their actual parent", MediaGallery.breadcrumbs(to: source, root: characters).map(\.lastPathComponent) == ["Notes", "Start.md"])

let markdown = FileReference.markdown(to: target, from: source)
check("tag uses portable escaped Markdown", markdown == "[@Design \\[v2\\] #1 (final).md](Nested/Design%20%5Bv2%5D%20%231%20%28final%29.md)")
let match = MarkdownHighlighter.linkText.firstMatch(in: markdown, range: NSRange(location: 0, length: (markdown as NSString).length))!
let destination = (markdown as NSString).substring(with: match.range(at: 2))
check("encoded path round trips", FileReference.resolve(destination, from: source) == target)
check("sibling reference traverses parent", FileReference.markdown(to: imageURL, from: source) == "[@Landscape.png](../Media/Landscape.png)")
let movedSource = URL(fileURLWithPath: "/relocated/project/Notes/Start.md")
check("whole project relocation preserves target", FileReference.resolve(destination, from: movedSource)?.path == "/relocated/project/Notes/Nested/Design [v2] #1 (final).md")
check("no remote destinations opened as files", FileReference.resolve("https://example.com", from: source) == nil)
check("binary files unsupported", FileKind.classify(unknown) == .unsupported)
check("images classified", FileKind.classify(imageURL) == .image)
let storage = NSTextStorage(string: markdown)
MarkdownHighlighter().highlight(storage)
check("tag has clickable destination", storage.attribute(.fileReference, at: 2, effectiveRange: nil) as? String == destination)
check("tag is royal blue", (storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor)?.isEqual(NSColor(hex: 0x4169E1)) == true)

let headingTag = NSTextStorage(string: "# " + markdown)
MarkdownHighlighter().highlight(headingTag)
check("tags in headings remain navigable", headingTag.attribute(.fileReference, at: 4, effectiveRange: nil) != nil)
let codeTag = NSTextStorage(string: "`" + markdown + "`")
MarkdownHighlighter().highlight(codeTag)
check("tag examples inside code stay literal", codeTag.attribute(.fileReference, at: 3, effectiveRange: nil) == nil)

let controller = EditorWindowController(app: nil)
controller.window?.setFrame(NSRect(x: 100, y: 100, width: 960, height: 720), display: true)
controller.showWindow(nil)
check("single-file starts without sidebar", controller.workspace == nil)
check("open markdown", controller.open(url: source))
let count = controller.documents.count
check("open folder", controller.open(url: root))
check("folder appends tab and keeps existing file", controller.documents.count == count + 1 && controller.documents[0].url == source)
check("folder sets root", controller.workspace?.root.path == root.path)
check("folder tab is gallery", controller.currentDocument.kind == .folder)
check("open image", controller.open(url: imageURL, forceNewTab: true))
check("image is read only", !controller.textView.isEditable)
let bytes = try Data(contentsOf: imageURL)
controller.saveDocument(nil); controller.saveDocumentAs(nil)
check("save cannot overwrite image", try Data(contentsOf: imageURL) == bytes)
check("open unknown", controller.open(url: unknown, forceNewTab: true))
check("unsupported is read only", controller.currentDocument.kind == .unsupported && !controller.textView.isEditable)
controller.saveDocument(nil)
check("save cannot overwrite binary", try Data(contentsOf: unknown) == Data([0, 255, 20, 19]))
check("replace root", controller.open(url: root.appendingPathComponent("Media")))
check("one active workspace replaced", controller.workspace?.root == root.appendingPathComponent("Media"))
check("old folder tab survives", controller.documents.contains { $0.url?.path == root.path })
controller.switchTab(to: 0)
check("markdown editor restored", controller.textView.isEditable && controller.textView.string.contains("# Start"))
controller.textView.insertText("extra", replacementRange: NSRange(location: controller.textView.string.utf16.count, length: 0))
controller.open(url: imageURL, forceNewTab: true)
check("markdown flushes before image tab", try String(contentsOf: source, encoding: .utf8).hasSuffix("extra"))

func snapshot(_ name: String) {
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    guard let view = controller.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/write-\(name).png"))
}
controller.restoreWorkspace(root: root, collapsed: false, width: 220, media: true)
controller.open(url: root.appendingPathComponent("Media"))
controller.restoreWorkspace(root: root, collapsed: false, width: 220, media: true)
snapshot("gallery")
let preview = controller.window!.contentView!.subviews.first { $0 is FilePreview } as! FilePreview
check("gallery loads multiple collection sections", preview.sections.count == 3)
let galleryScroll = preview.subviews.first { $0 is NSScrollView } as! NSScrollView
let groupedCollection = galleryScroll.documentView as! NSCollectionView
groupedCollection.scrollToItems(at: Set([IndexPath(item: 0, section: 1)]), scrollPosition: .top)
snapshot("gallery-grouped")
var galleryPosition = galleryScroll.contentView.bounds.origin
func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
let bar = controller.window!.contentView!.subviews.first { $0 is TabBarView }!
let strip = bar.subviews.first { $0 is NSScrollView } as! NSScrollView
let control = descendants(bar).compactMap { $0 as? NSButton }.first { $0.toolTip == "Collapse sidebar" }!
let tab = descendants(strip).first { String(describing: type(of: $0)) == "TabItemView" }!
check("sidebar controls align to tab centers", abs(control.convert(control.bounds, to: bar).midY - tab.convert(tab.bounds, to: bar).midY) < 0.5)
check("tab viewport reaches window edge", abs(strip.frame.maxX - bar.bounds.width) < 0.5)
controller.window?.setContentSize(NSSize(width: 640, height: 720))
controller.window?.contentView?.layoutSubtreeIfNeeded()
controller.switchTab(to: controller.current)
check("tabs overflow in a scrollable document", strip.documentView!.frame.width > strip.contentView.bounds.width)
let lastTab = descendants(strip).filter { String(describing: type(of: $0)) == "TabItemView" }.last!
check("selected last tab remains fully visible", strip.documentVisibleRect.contains(lastTab.frame))
snapshot("tabs-overflow")
controller.window?.setContentSize(NSSize(width: 960, height: 720))
controller.window?.contentView?.layoutSubtreeIfNeeded()

galleryPosition = galleryScroll.contentView.bounds.origin
controller.open(url: imageURL, forceNewTab: true)
snapshot("image")
let imageCrumbs = preview.subviews.first { $0 is BreadcrumbBar } as! BreadcrumbBar
check("media images show breadcrumbs", !imageCrumbs.isHidden)
let mediaCrumb = descendants(imageCrumbs).compactMap { $0 as? NSButton }.first { $0.title == "Media" }!
let beforeBack = controller.documents.count
mediaCrumb.performClick(nil)
check("breadcrumb returns to existing gallery tab", controller.currentDocument.kind == .folder && controller.currentDocument.url?.path == root.appendingPathComponent("Media").path && controller.documents.count == beforeBack)
check("breadcrumb navigation preserves workspace", controller.workspace?.root.path == root.path)
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
check("back to gallery restores scroll position", abs(galleryScroll.contentView.bounds.origin.y - galleryPosition.y) < 1)
controller.restoreWorkspace(root: root, collapsed: false, width: 220, media: false)
controller.open(url: imageURL, forceNewTab: true)
check("Files image view has no heading or breadcrumb", imageCrumbs.isHidden)
snapshot("image-files")

controller.restoreWorkspace(root: root, collapsed: true, width: 220, media: false)
controller.switchTab(to: 0)
snapshot("collapsed")
check("collapsed body uses full width", abs(controller.textView.enclosingScrollView!.frame.minX) < 0.5)
controller.restoreWorkspace(root: root, collapsed: false, width: 220, media: false)
controller.window?.contentView?.layoutSubtreeIfNeeded()
let sidebarView = controller.window!.contentView!.subviews.first { $0 is FolderSidebar }!
check("expanded sidebar has saved width", sidebarView.frame.width == 220)
let deadline = Date().addingTimeInterval(3)
while controller.workspace?.files.isEmpty == true && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
check("workspace indexes nested and arbitrary files", controller.workspace?.files.contains { $0.standardizedFileURL.path == target.standardizedFileURL.path } == true && controller.workspace?.files.contains { $0.standardizedFileURL.path == unknown.standardizedFileURL.path } == true)
controller.textView.setSelectedRange(NSRange(location: controller.textView.string.utf16.count, length: 0))
controller.textView.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
controller.textView.insertText("@", replacementRange: NSRange(location: NSNotFound, length: 0))
func key(_ text: String, _ code: UInt16) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                windowNumber: controller.window!.windowNumber, context: nil,
                                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    controller.textView.keyDown(with: event)
}
key("Design", 0)
key("\r", 36)
check("@ picker inserts chosen relative Markdown", controller.textView.string.hasSuffix(markdown))
snapshot("references")
let referenceIndex = (controller.textView.string as NSString).range(of: "@Design").location
if referenceIndex != NSNotFound, let lm = controller.textView.layoutManager, let tc = controller.textView.textContainer {
    lm.ensureLayout(for: tc)
    let glyph = lm.glyphIndexForCharacter(at: referenceIndex)
    let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
    let origin = controller.textView.textContainerOrigin
    let point = controller.textView.convert(NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y), to: nil)
    let click = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                  windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    controller.textView.mouseDown(with: click)
    check("clicking tag opens its target tab", controller.currentDocument.url == target)
}
controller.closeFolder(nil)
check("close folder keeps tabs and disables sidebar", controller.workspace == nil && controller.documents.count > 1 && !controller.textView.referencesEnabled)
let restored = EditorWindowController(app: nil)
restored.restoreTab(url: root)
restored.restoreTab(url: imageURL)
restored.restoreWorkspace(root: root.appendingPathComponent("Media"), collapsed: true, width: 270, media: true)
check("restored folder tabs don't replace root", restored.workspace?.root == root.appendingPathComponent("Media") && restored.documents.count == 2)
check("sidebar preferences restore", restored.sidebarCollapsed && restored.sidebarWidth == 270 && restored.mediaMode)
check("persist preview tabs safely", restored.persistAllDrafts())
controller.window?.orderOut(nil); restored.window?.orderOut(nil)
print(failures == 0 ? "ALL WORKSPACE TESTS PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
