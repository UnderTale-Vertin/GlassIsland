import Foundation
import Combine

/// Data coordinator: reads the note, extracts tasks, performs toggles and
/// undo, and publishes UI state. Message flow mirrors the original app.mjs.
final class TaskStore: ObservableObject {
    struct Notice: Equatable {
        var text: String
        var isError: Bool
        var autoDismissAfter: TimeInterval?
    }

    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var sourceText: String?
    @Published private(set) var statusText: String = "Connecting to note…"
    @Published private(set) var notice: Notice?
    @Published private(set) var undoTask: ToggleResult?
    @Published private(set) var pending = false
    @Published private(set) var pendingItemID: String?
    @Published private(set) var configured = false
    @Published private(set) var sourceIsFolder = false

    private let configProvider: () -> Config
    private let bridge: MarkdownBridge
    private let watcher = NoteWatcher()
    private let reloadQueue = DispatchQueue(label: "GlassIsland.Reload", qos: .userInitiated)
    private var noticeTimer: DispatchSourceTimer?
    private var pendingTimeout: DispatchWorkItem?
    private var onConfigChanged: (() -> Void)?

    init(configProvider: @escaping () -> Config, bridge: MarkdownBridge) {
        self.configProvider = configProvider
        self.bridge = bridge
        watcher.onChange = { [weak self] in self?.refresh() }
    }

    func setOnConfigChanged(_ handler: @escaping () -> Void) {
        onConfigChanged = handler
    }

    func start() {
        let path = configProvider().sourcePath
        configured = configProvider().isConfigured
        if !path.isEmpty {
            watcher.start(path: path)
        }
        refresh()
    }

    /// Re-arm watching after the note path changes.
    func reloadConfiguration() {
        let cfg = configProvider()
        configured = cfg.isConfigured
        if !cfg.sourcePath.isEmpty {
            watcher.start(path: cfg.sourcePath)
        }
        sourceText = nil
        tasks = []
        undoTask = nil
        notice = nil
        statusText = "Connecting to note…"
        refresh()
        onConfigChanged?()
    }

    func refresh() {
        reloadQueue.async { [weak self] in self?.reloadSync() }
    }

    private func reloadSync() {
        let cfg = configProvider()
        configured = cfg.isConfigured
        guard cfg.isConfigured, !cfg.sourcePath.isEmpty else {
            DispatchQueue.main.async {
                self.sourceText = nil
                self.tasks = []
                self.statusText = "Note unavailable"
                self.showNotice(Notice(text: "找不到任务收件箱。", isError: true, autoDismissAfter: nil))
            }
            return
        }
        var items: [TaskItem] = []
        do {
            items = try loadTasks(sourcePath: cfg.sourcePath, vault: cfg.vault, noteFile: cfg.noteFile)
        } catch {
            DispatchQueue.main.async {
                self.statusText = "Note unavailable"
                self.showNotice(Notice(text: error.localizedDescription, isError: true, autoDismissAfter: nil))
            }
            return
        }
        DispatchQueue.main.async {
            let reconnected = self.statusText == "Note unavailable" && self.sourceText != nil
            self.sourceText = "loaded"
            self.tasks = items
            self.statusText = "Obsidian · Auto sync"
            if reconnected {
                self.showNotice(Notice(text: "笔记已重新连接", isError: false, autoDismissAfter: 3))
            } else if self.notice?.isError == true, self.notice?.text == "找不到任务收件箱。" {
                self.showNotice(nil)
            }
        }
    }

    /// Reads the configured source. A directory source aggregates every
    /// Markdown file inside it (hidden folders skipped); a file source is
    /// the single note. Items carry their file so write-back stays exact.
    func loadTasks(sourcePath: String, vault: String, noteFile: String) throws -> [TaskItem] {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDir)
        guard exists else { throw WriteBackError.noteMissing }
        sourceIsFolder = isDir.boolValue
        if !isDir.boolValue {
            guard let data = FileManager.default.contents(atPath: sourcePath),
                  let text = String(data: data, encoding: .utf8) else { throw WriteBackError.notUTF8 }
            return try bridge.extractTasks(from: text, vault: vault, noteFile: noteFile)
                .map { item in var i = item; i.filePath = sourcePath; return i }
        }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: sourcePath), includingPropertiesForKeys: nil) else {
            throw WriteBackError.noteMissing
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            if ext == "md" || ext == "markdown" { files.append(url) }
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var items: [TaskItem] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let relative = noteFileFor(file: file, sourcePath: sourcePath, vault: vault)
            for var item in try bridge.extractTasks(from: text, vault: vault, noteFile: relative) {
                item.filePath = file.path
                items.append(item)
            }
        }
        return items
    }

    /// Obsidian links need vault-relative paths; without a resolvable vault
    /// fall back to folder-relative (single-note mode always uses noteFile).
    private func noteFileFor(file: URL, sourcePath: String, vault: String) -> String {
        if let vaultPath = ObsidianSupport.vaultPath(named: vault),
           file.path.hasPrefix(vaultPath + "/") {
            return String(file.path.dropFirst(vaultPath.count + 1))
        }
        let baseLength = (sourcePath as NSString).length
        return (file.path as NSString).substring(from: baseLength + 1)
    }

    // MARK: - Actions

    /// Complete a task: write-back to its note, then refresh. Mirrors the
    /// original checkbox handler including its pending guard and 20s timeout.
    func toggle(_ item: TaskItem) {
        guard !pending else {
            showNotice(Notice(text: "正在保存上一项操作，请稍候", isError: true, autoDismissAfter: nil))
            return
        }
        let cfg = configProvider()
        guard cfg.isConfigured else {
            showNotice(Notice(text: "找不到任务收件箱。", isError: true, autoDismissAfter: nil))
            return
        }
        pending = true
        pendingItemID = item.id
        let token = UUID()
        pendingTimeout = DispatchWorkItem { [weak self] in
            guard let self, self.pending, self.pendingToken == token else { return }
            self.pending = false
            self.pendingItemID = nil
            self.showNotice(Notice(text: "未收到保存结果，请核对笔记后再操作", isError: true, autoDismissAfter: nil))
            self.refresh()
        }
        if let timeout = pendingTimeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        }
        pendingToken = token

        let path = item.filePath.isEmpty ? cfg.sourcePath : item.filePath
        DiagLog.log("toggle → \(path) line\(item.lineNumber) done=true")
        reloadQueue.async { [weak self] in
            defer { DispatchQueue.main.async { self?.pending = false; self?.pendingItemID = nil } }
            do {
                let result = try TaskWriter.toggle(sourcePath: path, line: item.line, lineNumber: item.lineNumber, done: true)
                DiagLog.log("toggle OK \(result.filePath) → line\(result.lineNumber)")
                DispatchQueue.main.async {
                    guard let self, self.pendingToken == token else { return }
                    self.pendingTimeout?.cancel()
                    self.undoTask = result
                    self.showNotice(Notice(text: "已完成一项", isError: false, autoDismissAfter: nil))
                }
                self?.suppressWatcher()
                self?.refresh()
            } catch {
                DiagLog.log("toggle FAILED: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    guard let self, self.pendingToken == token else { return }
                    self.pendingTimeout?.cancel()
                    self.showNotice(Notice(text: error.localizedDescription, isError: true, autoDismissAfter: nil))
                }
                self?.refresh()
            }
        }
    }

    /// Undo the most recent completion (toggles the recorded line back).
    func undo() {
        guard let task = undoTask, !pending else { return }
        let cfg = configProvider()
        guard cfg.isConfigured else { return }
        pending = true
        pendingItemID = task.line
        DiagLog.log("undo → \(task.filePath) line\(task.lineNumber)")
        reloadQueue.async { [weak self] in
            defer { DispatchQueue.main.async { self?.pending = false } }
            do {
                let result = try TaskWriter.toggle(sourcePath: task.filePath, line: task.line, lineNumber: task.lineNumber, done: false)
                DiagLog.log("undo OK \(result.filePath) → line\(result.lineNumber)")
                DispatchQueue.main.async {
                    self?.undoTask = nil
                    self?.showNotice(Notice(text: "已撤销完成", isError: false, autoDismissAfter: 3))
                }
                self?.suppressWatcher()
                self?.refresh()
            } catch {
                DiagLog.log("undo FAILED: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.showNotice(Notice(text: error.localizedDescription, isError: true, autoDismissAfter: nil))
                }
                self?.refresh()
            }
        }
    }

    func openNote() {
        guard configProvider().isConfigured else {
            showNotice(Notice(text: "先在「…」菜单里选择一篇任务笔记", isError: false, autoDismissAfter: 4))
            return
        }
        let cfg = configProvider()
        openLink(urlString: OpenLink.noteURL(vault: cfg.vault, noteFile: cfg.noteFile))
    }

    func openLink(urlString: String) {
        do {
            try OpenLink.open(urlString: urlString, vault: configProvider().vault)
        } catch {
            showNotice(Notice(text: error.localizedDescription, isError: true, autoDismissAfter: nil))
        }
    }

    // MARK: - Notices

    func showNotice(_ notice: Notice?) {
        noticeTimer?.cancel()
        noticeTimer = nil
        self.notice = notice
        if let after = notice?.autoDismissAfter {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + after)
            timer.setEventHandler { [weak self] in
                guard let self, self.notice == notice else { return }
                self.notice = nil
            }
            timer.resume()
            noticeTimer = timer
        }
    }

    private func suppressWatcher() {
        watcher.suppressFor(1.2)
    }

    private var pendingToken = UUID()
}
