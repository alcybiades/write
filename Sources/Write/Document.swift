import AppKit

/// One open buffer: a tab owns its text storage, undo stack, and selection.
final class Document {
    var url: URL?
    let storage: NSTextStorage
    let undoManager = UndoManager()
    var selection = NSRange(location: 0, length: 0)
    var edited = false
    /// Title chosen before the document has a file (used as the save name).
    var customTitle: String?
    /// Names this buffer's crash-recovery draft across launches.
    var recoveryID = UUID()

    init(url: URL? = nil, content: String = "") {
        self.url = url
        storage = NSTextStorage(string: content, attributes: Theme.baseAttributes)
    }

    var name: String { url?.lastPathComponent ?? customTitle ?? "untitled" }

    /// The filename without extension — what the inline title shows.
    var displayTitle: String {
        if let url { return url.deletingPathExtension().lastPathComponent }
        return customTitle ?? "untitled"
    }
}
