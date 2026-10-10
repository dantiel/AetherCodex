import Cocoa

/// A node in the file system outline — file or directory.
final class FileItem: NSObject {
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileItem]?
    var isLoaded = false

    /// Global veil toggle — when lifted, dotfiles enter every directory.
    /// A single switch for the whole tree keeps the hermetic symmetry:
    /// what is hidden is hidden everywhere, or revealed everywhere.
    static var showsHiddenFiles = false

    /// Forget loaded children so the next expansion re-reads the disk.
    func invalidate() {
        children = nil
        isLoaded = false
    }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        super.init()
    }

    /// Sort: directories first, then alphabetical (case-insensitive).
    func loadChildren() {
        guard isDirectory, !isLoaded else { return }
        isLoaded = true
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: FileItem.showsHiddenFiles ? [] : [.skipsHiddenFiles]
        ) else {
            children = []
            return
        }
        children = contents.compactMap { u -> FileItem? in
            guard let rv = try? u.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDir = rv.isDirectory else { return nil }
            // Skip files without extensions and non-package dirs we can't read
            if isDir {
                guard (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [])) != nil else { return nil }
            }
            return FileItem(url: u, isDirectory: isDir)
        }
        children?.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}