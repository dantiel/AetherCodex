import Foundation

/// Watches a single file for on-disk changes via a `DispatchSource` vnode
/// source. The source is level-triggered, so a single external write can fire
/// repeatedly; the owner (an `EditorViewController`) is responsible for
/// debouncing by re-statting and comparing against its own baseline
/// (modification date + size). The watcher itself stays dumb: it only reports
/// *that* the file node changed, never *what* changed.
final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private(set) var url: URL?

    /// Fired on `.write`, `.extend`, `.rename`, `.delete` and `.attrib` events.
    var onChange: (() -> Void)?

    /// Begin watching `url`. Re-watching the same or a new URL closes the
    /// previous descriptor — call this again whenever the file is saved or
    /// reloaded (atomic writes replace the inode, orphaning the old fd).
    func watch(_ url: URL) {
        stop()
        self.url = url
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.fd = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.onChange?()
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 {
                close(self.fd)
                self.fd = -1
            }
        }
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        url = nil
    }

    deinit {
        stop()
    }
}
