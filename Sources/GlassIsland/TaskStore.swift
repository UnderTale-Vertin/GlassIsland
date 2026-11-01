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
    @Published private(set) var pendingLine: String?
    @Published private(set) var configured = false

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
        guard cfg.isConfigured, !cfg.sourcePath.isEmpty,
              let data = FileManager.default.contents(atPath: cfg.sourcePath),
              let text = String(data: data, encoding: .utf8) else {
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
            items = try bridge.extractTasks(from: text, vault: cfg.vault, noteFile: cfg.noteFile)
        } catch {
            DispatchQueue.main.async {
                self.statusText = "Note unavailable"
                self.showNotice(Notice(text: error.localizedDescription, isError: true, autoDismissAfter: nil))
            }
            return
        }
        DispatchQueue.main.async {
            let reconnected = self.statusText == "Note unavailable" && self.sourceText != nil
            self.sourceText = text
            self.tasks = items
            self.statusText = "Obsidian · Auto sync"
            if reconnected {
                self.showNotice(Notice(text: "笔记已重新连接", isError: false, autoDismissAfter: 3))
            } else if self.notice?.isError == true, self.notice?.text == "找不到任务收件箱。" {
                self.showNotice(nil)
            }
        }
    }

    // MARK: - Actions

    /// Complete a task: write-back to the note, then refresh. Mirrors the
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
        pendingLine = item.line
        let token = UUID()
        pendingTimeout = DispatchWorkItem { [weak self] in
            guard let self, self.pending, self.pendingToken == token else { return }
            self.pending = false
            self.pendingLine = nil
            self.showNotice(Notice(text: "未收到保存结果，请核对笔记后再操作", isError: true, autoDismissAfter: nil))
            self.refresh()
        }
        if let timeout = pendingTimeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        }
        pendingToken = token

        let path = cfg.sourcePath
        reloadQueue.async { [weak self] in
            defer { DispatchQueue.main.async { self?.pending = false; self?.pendingLine = nil } }
            do {
                let result = try TaskWriter.toggle(sourcePath: path, line: item.line, lineNumber: item.lineNumber, done: true)
                DispatchQueue.main.async {
                    guard let self, self.pendingToken == token else { return }
                    self.pendingTimeout?.cancel()
                    self.undoTask = result
                    self.showNotice(Notice(text: "已完成一项", isError: false, autoDismissAfter: nil))
                }
                self?.suppressWatcher()
                self?.refresh()
            } catch {
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
        let path = cfg.sourcePath
        reloadQueue.async { [weak self] in
            defer { DispatchQueue.main.async { self?.pending = false } }
            do {
                _ = try TaskWriter.toggle(sourcePath: path, line: task.line, lineNumber: task.lineNumber, done: false)
                DispatchQueue.main.async {
                    self?.undoTask = nil
                    self?.showNotice(Notice(text: "已撤销完成", isError: false, autoDismissAfter: 3))
                }
                self?.suppressWatcher()
                self?.refresh()
            } catch {
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
