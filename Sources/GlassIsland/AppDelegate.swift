import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config.load()
    private var bridge: MarkdownBridge?
    private var store: TaskStore?
    private var model: IslandModel?
    private var controller: IslandController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // GLASSISLAND_DIAG=1: dump windows without showing the island; =2:
        // run the normal launch flow first, then dump. Either way exits.
        let diagnosticMode = ProcessInfo.processInfo.environment["GLASSISLAND_DIAG"]
        if diagnosticMode != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                NSLog("DIAG config sourcePath='%@' exists=%d", self.config.sourcePath,
                      FileManager.default.fileExists(atPath: self.config.sourcePath) ? 1 : 0)
                for window in NSApp.windows {
                    NSLog("DIAG class=%@ frame=%@ title='%@' visible=%@ level=%d",
                          window.className,
                          NSStringFromRect(window.frame),
                          window.title,
                          window.isVisible ? "yes" : "no",
                          window.level.rawValue)
                }
                exit(0)
            }
        }
        Res.registerFonts()
        do {
            bridge = try MarkdownBridge()
        } catch {
            presentFatal(message: error.localizedDescription)
            return
        }
        let store = TaskStore(configProvider: { [weak self] in self?.config ?? Config() }, bridge: bridge!)
        self.store = store
        let model = IslandModel(mode: config.mode)
        self.model = model
        let controller = IslandController(model: model, store: store, configProvider: { [weak self] in self?.config ?? Config() })
        self.controller = controller
        model.onMenuAction = { [weak self] action in self?.handleMenuAction(action) }
        model.onTop = config.pinnedOnTop
        store.setOnConfigChanged { [weak self] in
            guard let self else { return }
            self.config = Config.load()
        }
        setupStatusItem()
        if config.isConfigured {
            store.start()
        }
        // Never auto-prompt: an unconfigured app shows a hint in the panel
        // and in the capsule; picking a note stays user-initiated.
        if diagnosticMode == nil {
            controller.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The note watcher stops with the process; nothing to persist here.
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "GlassIsland")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = self.store
        let model = self.model

        let refresh = NSMenuItem(title: "立即刷新", action: #selector(menuRefresh(_:)), keyEquivalent: "r")
        refresh.keyEquivalentModifierMask = []
        menu.addItem(refresh)
        let open = NSMenuItem(title: "在 Obsidian 中打开", action: store != nil && config.isConfigured ? #selector(menuOpenNote(_:)) : nil, keyEquivalent: "o")
        open.keyEquivalentModifierMask = []
        menu.addItem(open)
        menu.addItem(.separator())

        let island = NSMenuItem(title: "灵动岛模式", action: model?.mode != .island ? #selector(menuIslandMode(_:)) : nil, keyEquivalent: "")
        island.state = model?.mode == .island ? .on : .off
        menu.addItem(island)
        let floating = NSMenuItem(title: "桌面浮窗模式", action: model?.mode != .floating ? #selector(menuFloatingMode(_:)) : nil, keyEquivalent: "")
        floating.state = model?.mode == .floating ? .on : .off
        menu.addItem(floating)
        if model?.mode == .floating {
            let onTop = NSMenuItem(title: "窗口置顶", action: #selector(menuToggleOnTop(_:)), keyEquivalent: "")
            onTop.state = config.pinnedOnTop ? .on : .off
            menu.addItem(onTop)
        } else {
            let pin = NSMenuItem(title: "固定展开（不随悬停收回）", action: #selector(menuTogglePin(_:)), keyEquivalent: "")
            pin.state = (model?.pinned ?? false) ? .on : .off
            menu.addItem(pin)
        }
        menu.addItem(.separator())

        let pick = NSMenuItem(title: "选择任务笔记…", action: #selector(menuPickNote(_:)), keyEquivalent: ",")
        pick.keyEquivalentModifierMask = [.command]
        menu.addItem(pick)
        let pathItem = NSMenuItem(title: noteSummary(), action: nil, keyEquivalent: "")
        pathItem.isEnabled = false
        menu.addItem(pathItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 GlassIsland", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        _ = store
    }

    private func noteSummary() -> String {
        guard config.isConfigured else { return "未配置任务笔记" }
        return (config.sourcePath as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Actions

    private func handleMenuAction(_ action: IslandModel.MenuAction) {
        switch action {
        case .toggleOnTop:
            toggleOnTop()
        case .switchMode:
            switchMode()
        case .refresh:
            store?.refresh()
        case .openNote:
            store?.openNote()
        case .pickNote:
            promptForNote(firstRun: false)
        case .pickFolder:
            promptForFolder()
        case .startObsidianPick:
            startObsidianPick()
        case .finishObsidianPick:
            finishObsidianPick()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    /// Lets the user pick the task source inside Obsidian: activate it, wait
    /// for them to open the target note, then resolve it from the window
    /// title plus Obsidian's vault registry.
    private func startObsidianPick() {
        guard ObsidianSupport.activateObsidian() else {
            store?.showNotice(TaskStore.Notice(
                text: "未检测到 Obsidian，请先安装，或改用「选择任务笔记…」",
                isError: true, autoDismissAfter: 6
            ))
            return
        }
        model?.pickingFromObsidian = true
        model?.showOptions = true
        store?.showNotice(TaskStore.Notice(
            text: "在 Obsidian 中打开目标笔记，然后点「完成：采用 Obsidian 当前笔记」",
            isError: false, autoDismissAfter: nil
        ))
    }

    private func finishObsidianPick() {
        model?.pickingFromObsidian = false
        let (title, needsPermission) = ObsidianSupport.frontWindowTitle()
        if needsPermission {
            store?.showNotice(TaskStore.Notice(
                text: "需要授权：系统设置 → 隐私与安全性 → 辅助功能/自动化，允许 GlassIsland 控制 Obsidian",
                isError: true, autoDismissAfter: 12
            ))
            return
        }
        guard let title, let source = ObsidianSupport.parseWindowTitle(title) else {
            store?.showNotice(TaskStore.Notice(
                text: "未检测到正在编辑的笔记，请先在 Obsidian 打开一篇笔记再试",
                isError: true, autoDismissAfter: 8
            ))
            return
        }
        guard let resolved = ObsidianSupport.resolveNote(
            noteName: source.noteName, vaultName: source.vaultName, vaults: ObsidianSupport.vaultPaths()
        ) else {
            store?.showNotice(TaskStore.Notice(
                text: "在笔记库「\(source.vaultName)」中找不到「\(source.noteName)」，请确认已保存该笔记",
                isError: true, autoDismissAfter: 8
            ))
            return
        }
        config.sourcePath = resolved.path
        config.vault = source.vaultName
        config.noteFile = noteFileRelativeToVault(resolved.path, vaultPath: resolved.vaultPath)
        config.save()
        DiagLog.log("obsidian pick → \(resolved.path) vault=\(source.vaultName)")
        store?.reloadConfiguration()
        store?.showNotice(TaskStore.Notice(text: "任务源已设为 \(source.noteName)", isError: false, autoDismissAfter: 4))
    }

    /// Folder source: watch every Markdown note inside a directory.
    private func promptForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择一个文件夹，GlassIsland 将监控其中全部 Markdown 笔记的待办"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.sourcePath = url.path
        if config.vault.isEmpty {
            config.vault = url.lastPathComponent
        }
        config.noteFile = url.lastPathComponent
        config.save()
        DiagLog.log("folder pick → \(url.path)")
        store?.reloadConfiguration()
        store?.showNotice(TaskStore.Notice(text: "已监控文件夹 \(url.lastPathComponent)", isError: false, autoDismissAfter: 4))
    }

    private func noteFileRelativeToVault(_ path: String, vaultPath: String) -> String {
        guard path.hasPrefix(vaultPath + "/") else { return (path as NSString).lastPathComponent }
        return String(path.dropFirst(vaultPath.count + 1))
    }

    @objc private func menuRefresh(_ sender: NSMenuItem) { store?.refresh() }
    @objc private func menuOpenNote(_ sender: NSMenuItem) { store?.openNote() }
    @objc private func menuIslandMode(_ sender: NSMenuItem) {
        if model?.mode != .island { switchMode() }
    }
    @objc private func menuFloatingMode(_ sender: NSMenuItem) {
        if model?.mode != .floating { switchMode() }
    }
    @objc private func menuTogglePin(_ sender: NSMenuItem) { model?.togglePin() }
    @objc private func menuToggleOnTop(_ sender: NSMenuItem) { toggleOnTop() }
    @objc private func menuPickNote(_ sender: NSMenuItem) { promptForNote(firstRun: false) }

    private func toggleOnTop() {
        config.pinnedOnTop.toggle()
        model?.onTop = config.pinnedOnTop
        config.save()
        controller?.refitForLevelChange()
    }

    private func switchMode() {
        guard let model else { return }
        let newMode: IslandMode = model.mode == .island ? .floating : .island
        model.setMode(newMode)
        config.mode = newMode
        config.save()
        controller?.applyModeChange(newMode)
    }

    // MARK: - Note picking

    private func promptForNote(firstRun: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .text, .init(filenameExtension: "markdown") ?? .text, .plainText]
        panel.message = "选择一篇包含 - [ ] 待办的 Markdown 笔记（只用这一篇，不会改动其他笔记）"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        configureNote(url: url)
    }

    private func configureNote(url: URL) {
        let alert = NSAlert()
        alert.messageText = "配置任务笔记"
        alert.informativeText = "笔记：\(url.path)\n\n笔记库名（vault）用于生成 Obsidian 跳转链接；笔记路径是相对笔记库的路径。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let vaultField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        vaultField.placeholderString = "vault 名称"
        vaultField.stringValue = url.deletingLastPathComponent().lastPathComponent
        let vaultLabel = NSTextField(labelWithString: "vault 名称：")

        let noteField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        noteField.placeholderString = "笔记库内路径，如 Inbox/Tasks.md"
        noteField.stringValue = url.lastPathComponent
        let noteLabel = NSTextField(labelWithString: "笔记库内路径：")

        let stack = NSStackView(views: [vaultLabel, vaultField, noteLabel, noteField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 300).isActive = true
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        config.sourcePath = url.path
        config.vault = vaultField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.noteFile = noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.noteFile.isEmpty { config.noteFile = url.lastPathComponent }
        if config.vault.isEmpty { config.vault = url.deletingLastPathComponent().lastPathComponent }
        config.save()
        store?.reloadConfiguration()
    }

    private func presentFatal(message: String) {
        let alert = NSAlert()
        alert.messageText = "GlassIsland"
        alert.informativeText = message
        alert.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }
}
