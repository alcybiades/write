import AppKit
import UniformTypeIdentifiers

/// Filesystem paths are identities; links are standard source-relative Markdown.
/// This deliberately needs no database, workspace ID, or proprietary URL scheme.
enum FileReference {
    static func relativePath(to target: URL, from directory: URL) -> String {
        let targetParts = target.standardizedFileURL.pathComponents
        let baseParts = directory.standardizedFileURL.pathComponents
        var common = 0
        while common < min(targetParts.count, baseParts.count), targetParts[common] == baseParts[common] { common += 1 }
        return (Array(repeating: "..", count: baseParts.count - common) + targetParts.dropFirst(common)).joined(separator: "/")
    }

    static func markdown(to target: URL, from source: URL) -> String {
        let path = relativePath(to: target, from: source.deletingLastPathComponent())
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        let encoded = path.addingPercentEncoding(withAllowedCharacters: safe) ?? path
        let name = target.lastPathComponent
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[@\(name)](\(encoded))"
    }

    static func resolve(_ destination: String, from source: URL) -> URL? {
        guard let url = URL(string: destination, relativeTo: source.deletingLastPathComponent().appendingPathComponent("", isDirectory: true)),
              url.isFileURL else { return nil }
        return url.absoluteURL.standardizedFileURL
    }
}

enum FileKind {
    case markdown, image, unsupported, folder
    static func classify(_ url: URL) -> FileKind {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return .folder }
        if ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) { return .markdown }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) { return .image }
        return .unsupported
    }
}

enum WorkspaceItemKind {
    case file, markdown, folder

    func create(named name: String, in directory: URL) throws -> URL {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains(":"), !name.contains("\0"), !name.hasPrefix(".") else {
            throw NSError(domain: "Write", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Enter a visible file or folder name without slashes or colons."])
        }
        if self == .markdown && !["md", "markdown"].contains((name as NSString).pathExtension.lowercased()) {
            name += ".md"
        }
        let url = directory.appendingPathComponent(name, isDirectory: self == .folder)
        if self == .folder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } else {
            // Exclusive creation also protects against a file appearing while the sheet is open.
            try Data().write(to: url, options: .withoutOverwriting)
        }
        return url
    }
}

final class FileNode {
    let url: URL
    let isDirectory: Bool
    private var cachedChildren: [FileNode]?
    init(_ url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        // Never recurse through symlinks (cycles and trees outside the workspace).
        isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
    }
    var children: [FileNode] {
        if let cachedChildren { return cachedChildren }
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        let nodes = urls.map(FileNode.init).sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        cachedChildren = nodes
        return nodes
    }
}

final class Workspace {
    let root: URL
    private(set) var files: [URL] = []
    private var generation = UUID()
    var onIndexChanged: (() -> Void)?
    init(root: URL) { self.root = root.standardizedFileURL; refreshIndex() }
    func refreshIndex() {
        let token = UUID(); generation = token
        let root = root
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var result: [URL] = []
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { enumerator?.skipDescendants(); continue }
                if values?.isDirectory != true { result.append(url) }
            }
            let sorted = result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.files = sorted
                self.onIndexChanged?()
            }
        }
    }
    func matches(_ query: String) -> [URL] {
        Array(files.filter { query.isEmpty || FileReference.relativePath(to: $0, from: root).localizedCaseInsensitiveContains(query) }.prefix(80))
    }
}
