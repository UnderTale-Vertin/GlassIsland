import Foundation

/// Watches the note file for external edits. Obsidian often saves atomically
/// (temp file + rename), which orphans a file-descriptor watch, so this also
/// watches the containing directory (rename/create events), recreates the
/// file watch, and runs a 2s stat poll as a final fallback. All reads happen
/// by path, never through a stale descriptor.
final class NoteWatcher {
    var onChange: () -> Void = {}

    private let queue: DispatchQueue
    private var path: String = ""
    private var dirFD: Int32 = -1
    private var fileFD: Int32 = -1
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private var suppressUntil: Date = .distantPast
    private var lastStat: (size: Int, mtime: Date)?

    init(queue: DispatchQueue = DispatchQueue(label: "GlassIsland.NoteWatcher", qos: .utility)) {
        self.queue = queue
    }

    func start(path: String) {
        queue.async { [weak self] in self?.startLocked(path: path) }
    }

    func stop() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    /// Briefly ignore filesystem events, used right after our own write-back.
    func suppressFor(_ interval: TimeInterval) {
        queue.async { [weak self] in
            self?.suppressUntil = Date().addingTimeInterval(interval)
            self?.recordStatLocked()
        }
    }

    // MARK: - Locked (queue-confined)

    private func startLocked(path: String) {
        stopLocked()
        self.path = path
        watchDirectoryLocked()
        watchFileLocked()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.pollLocked() }
        timer.resume()
        pollTimer = timer
        recordStatLocked()
    }

    private func stopLocked() {
        dirSource?.cancel(); dirSource = nil; dirFD = -1
        fileSource?.cancel(); fileSource = nil; fileFD = -1
        pollTimer?.cancel(); pollTimer = nil
        debounce?.cancel(); debounce = nil
        lastStat = nil
        path = ""
    }

    private func watchDirectoryLocked() {
        let dir = (path as NSString).deletingLastPathComponent
        guard !dir.isEmpty else { return }
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        dirFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // An atomic save replaced the note: re-arm the file watch.
            self.watchFileLocked()
            self.scheduleChangeLocked()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
    }

    private func watchFileLocked() {
        if fileSource != nil {
            fileSource?.cancel()
            fileSource = nil
            fileFD = -1
        }
        guard !path.isEmpty else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = source.data
            if mask.contains(.delete) || mask.contains(.rename) || mask.contains(.revoke) {
                self.watchFileLocked()
            }
            self.scheduleChangeLocked()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    private func pollLocked() {
        guard let stat = statLocked() else { return }
        if stat.size != lastStat?.size || stat.mtime != lastStat?.mtime {
            recordStatLocked()
            scheduleChangeLocked()
        }
    }

    private func statLocked() -> (size: Int, mtime: Date)? {
        let attrs: [FileAttributeKey: Any]? = try? FileManager.default.attributesOfItem(atPath: path)
        guard let attrs else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        return (size, mtime)
    }

    private func recordStatLocked() {
        lastStat = statLocked()
    }

    private func scheduleChangeLocked() {
        guard Date() >= suppressUntil else {
            recordStatLocked()
            return
        }
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.recordStatLocked()
            guard Date() >= self.suppressUntil else { return }
            self.onChange()
        }
        queue.asyncAfter(deadline: .now() + 0.2, execute: item)
        debounce = item
    }
}
