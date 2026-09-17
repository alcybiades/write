import AppKit
import ImageIO

private final class MediaItem: NSCollectionViewItem {
    private var representedURL: URL?
    private var request: ImageRequest?
    private var generation = UUID()
    private var loadedPixels = 0
    override func loadView() {
        view = NSView()
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: "")
        label.font = Theme.font(size: 10)
        label.textColor = Theme.dim
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        view.addSubview(image); view.addSubview(label)
        image.translatesAutoresizingMaskIntoConstraints = false; label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: view.topAnchor, constant: 4), image.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            image.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4), image.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -8),
            label.heightAnchor.constraint(equalToConstant: 16),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5), label.leadingAnchor.constraint(equalTo: view.leadingAnchor), label.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        imageView = image; textField = label
    }
    func configure(_ url: URL) {
        stopLoading()
        representedURL = url
        textField?.stringValue = url.lastPathComponent
        view.toolTip = url.lastPathComponent
    }
    func loadThumbnail(scale: CGFloat) {
        guard let url = representedURL else { return }
        let pixels = ImageLoader.thumbnailPixels(points: 160, scale: scale)
        guard request == nil || loadedPixels != pixels else { return }
        request?.cancel()
        generation = UUID(); let token = generation
        loadedPixels = pixels
        imageView?.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Loading image")
        request = ImageLoader.shared.thumbnail(url, pixels: pixels) { [weak self] image in
            guard let self, self.generation == token else { return }
            self.imageView?.image = image ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Unable to load image")
        }
    }
    func stopLoading() {
        request?.cancel(); request = nil
        generation = UUID(); loadedPixels = 0
        imageView?.image = nil
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        stopLoading()
        representedURL = nil
    }

}

final class FilePreview: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var onOpen: ((URL, NSRect) -> Void)?
    var onNavigate: ((URL) -> Void)?
    private let scroll = NSScrollView()
    private let collection = NSCollectionView()
    private let imageView = NSImageView()
    private let message = NSTextField(labelWithString: "")
    private let breadcrumbs = BreadcrumbBar()
    private(set) var sections: [MediaSection] = []
    private var breadcrumbRoot: URL?
    private var galleryURL: URL?
    private var galleryPositions: [String: NSPoint] = [:]
    private var loadID = UUID()
    private var scan: BlockOperation?
    private var originalRequest: ImageRequest?
    private let scanQueue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated; return queue
    }()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 160, height: 156)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 18
        layout.sectionInset = NSEdgeInsets(top: 8, left: 20, bottom: 24, right: 20)
        layout.headerReferenceSize = NSSize(width: 1, height: 34)
        collection.collectionViewLayout = layout
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.dataSource = self; collection.delegate = self
        collection.register(MediaItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("media"))
        collection.register(GalleryHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: NSUserInterfaceItemIdentifier("path"))
        scroll.documentView = collection
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        message.font = Theme.font(size: 14); message.textColor = Theme.dim; message.alignment = .center
        breadcrumbs.onNavigate = { [weak self] url in self?.onNavigate?(url) }
        [scroll, imageView, message, breadcrumbs].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func layout() {
        super.layout()
        breadcrumbs.frame = NSRect(x: 24, y: bounds.height - 40, width: max(0, bounds.width - 48), height: 28)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 8))
        imageView.frame = imageFrame
        message.frame = NSRect(x: 20, y: bounds.midY - 30, width: max(0, bounds.width - 40), height: 60)
    }
    private var imageFrame: NSRect {
        let top: CGFloat = breadcrumbs.isHidden ? 24 : 52
        return NSRect(x: 24, y: 24, width: max(0, bounds.width - 48), height: max(0, bounds.height - top - 24))
    }
    func suspend() {
        if let galleryURL { galleryPositions[galleryURL.path] = scroll.contentView.bounds.origin }
        galleryURL = nil
        scan?.cancel()
        originalRequest?.cancel(); originalRequest = nil
        imageView.image = nil
        for item in collection.visibleItems() { (item as? MediaItem)?.stopLoading() }
        // Discard cells and their images when leaving a gallery; retain only
        // its scroll position, not decoded pixels hidden behind another tab.
        if !sections.isEmpty {
            sections = []
            collection.reloadData()
        }
        loadID = UUID()
    }
    func show(_ doc: Document, root: URL? = nil, mediaMode: Bool = false, from origin: NSRect? = nil) {
        suspend()
        let token = loadID
        breadcrumbRoot = root
        imageView.image = nil
        scroll.isHidden = doc.kind != .folder
        imageView.isHidden = doc.kind != .image
        breadcrumbs.isHidden = doc.kind != .image || !mediaMode
        message.isHidden = true
        guard let url = doc.url else { return }
        if !breadcrumbs.isHidden { breadcrumbs.configure(url: url, root: root, isImage: true) }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if doc.kind == .folder {
            galleryURL = url
            sections = []
            collection.reloadData()
            message.stringValue = "Loading images…"; message.isHidden = false
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation] in
                guard operation?.isCancelled == false else { return }
                let result = Result { try MediaGallery.sections(in: url, cancelled: { operation?.isCancelled != false }) }
                guard operation?.isCancelled == false else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.loadID == token else { return }
                    switch result {
                    case .success(let sections):
                        self.sections = sections
                        self.message.stringValue = "No images in this folder or its subfolders"
                    case .failure:
                        self.sections = []
                        self.message.stringValue = "This folder could not be read"
                    }
                    self.message.isHidden = !self.sections.isEmpty
                    self.collection.reloadData()
                    self.collection.selectionIndexPaths = []
                    self.collection.layoutSubtreeIfNeeded()
                    self.scroll.contentView.scroll(to: self.galleryPositions[url.path] ?? .zero)
                    self.scroll.reflectScrolledClipView(self.scroll.contentView)
                }
            }
            scan = operation; scanQueue.addOperation(operation)
        } else if doc.kind == .image {
            message.stringValue = "Loading image…"; message.isHidden = false
            originalRequest = ImageLoader.shared.original(url) { [weak self] image in
                guard let self, self.loadID == token else { return }
                self.imageView.image = image
                self.message.stringValue = "This image could not be loaded"
                self.message.isHidden = image != nil
                if let origin, image != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    self.imageView.frame = self.convert(origin, from: nil)
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.24
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        self.imageView.animator().frame = self.imageFrame
                    }
                }
            }
        } else {
            message.stringValue = "Rendering not yet supported"
            message.isHidden = false
        }
    }
    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].images.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("media"), for: indexPath) as! MediaItem
        item.configure(sections[indexPath.section].images[indexPath.item]); return item
    }
    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        guard !isHidden, galleryURL != nil else { return }
        (item as? MediaItem)?.loadThumbnail(scale: window?.backingScaleFactor ?? 2)
    }
    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        (item as? MediaItem)?.stopLoading()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard galleryURL != nil, !isHidden else { return }
        for item in collection.visibleItems() {
            (item as? MediaItem)?.loadThumbnail(scale: window?.backingScaleFactor ?? 2)
        }
    }
    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: NSUserInterfaceItemIdentifier("path"), for: indexPath) as! GalleryHeader
        header.breadcrumbs.configure(url: sections[indexPath.section].directory, root: breadcrumbRoot ?? galleryURL)
        header.breadcrumbs.onNavigate = { [weak self] url in self?.onNavigate?(url) }
        return header
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let path = indexPaths.first, sections.indices.contains(path.section), sections[path.section].images.indices.contains(path.item),
              let item = collectionView.item(at: path) else { return }
        let image = item.imageView ?? item.view
        onOpen?(sections[path.section].images[path.item], image.convert(image.bounds, to: nil))
    }
}
