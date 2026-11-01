import AppKit
import Combine

// AppKit palette (mirrors the original style.css dark glass theme).
private enum Ink {
    static let ink = NSColor(red: 0.949, green: 0.965, blue: 0.980, alpha: 1)
    static let muted = NSColor(red: 0.839, green: 0.878, blue: 0.914, alpha: 1)
    static let blue = NSColor(red: 0.757, green: 0.898, blue: 1.0, alpha: 1)
    static let checkBorder = NSColor(red: 0.714, green: 0.788, blue: 0.851, alpha: 1)
    static let checkHover = NSColor(red: 0.612, green: 0.824, blue: 1.0, alpha: 1)
    static let errorText = NSColor(red: 1.0, green: 0.827, blue: 0.780, alpha: 1)
    static let hoverRow = NSColor.white.withAlphaComponent(0.06)
    static let control = NSColor.white.withAlphaComponent(0.09)
    static let rowLine = NSColor.white.withAlphaComponent(0.10)
    static let undoBackground = NSColor(red: 0.314, green: 0.541, blue: 0.710, alpha: 0.10)
}

// MARK: - Hoverable icon button

final class IconButtonView: NSView {
    var action: () -> Void = {}
    private let imageView = NSImageView()
    private var hovering = false {
        didSet { updateLook() }
    }

    init(systemName: String, help: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        toolTip = help
        imageView.image = NSImage(systemSymbolName: systemName, accessibilityDescription: help)
        imageView.contentTintColor = Ink.muted
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    private func updateLook() {
        layer?.backgroundColor = hovering ? Ink.control.cgColor : NSColor.clear.cgColor
        imageView.contentTintColor = hovering ? Ink.blue : Ink.muted
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds.insetBy(dx: 8.5, dy: 8.5)
    }

    override func mouseDown(with event: NSEvent) {
        DiagLog.log("icon \(toolTip ?? "")")
        DispatchQueue.main.async { self.action() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

// MARK: - Clickable text (undo)

final class ClickableLabel: NSTextField {
    var onTap: () -> Void = {}
    override func mouseDown(with event: NSEvent) {
        DiagLog.log("label \(stringValue)")
        DispatchQueue.main.async { self.onTap() }
    }
}

// MARK: - Option row

final class OptionRowView: NSView {
    var action: () -> Void = {}
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hovering = false {
        didSet { layer?.backgroundColor = hovering ? Ink.control.cgColor : NSColor.clear.cgColor }
    }

    init(icon: String, label text: String, destructive: Bool = false, highlight: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        toolTip = text
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: text)
        iconView.contentTintColor = highlight ? Ink.blue : Ink.muted
        label.stringValue = text
        label.font = .systemFont(ofSize: 13)
        label.textColor = destructive ? Ink.errorText : (highlight ? Ink.ink : Ink.muted)
        addSubview(iconView)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 10, y: (bounds.height - 13) / 2, width: 13, height: 13)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 30, y: (bounds.height - label.frame.height) / 2)
    }

    override func mouseDown(with event: NSEvent) {
        DiagLog.log("option \(label.stringValue)")
        DispatchQueue.main.async { self.action() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

// MARK: - Task circle

final class CircleCheckView: NSView {
    var action: () -> Void = {}
    var onHover: ((Bool) -> Void)?
    var hovering = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 6
        let circle = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(ovalIn: circle)
        NSColor.white.withAlphaComponent(hovering ? 0.13 : 0.08).setFill()
        path.fill()
        (hovering ? Ink.checkHover : Ink.checkBorder).setStroke()
        path.lineWidth = 1.4
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        DiagLog.log("circle click")
        DispatchQueue.main.async { self.action() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; onHover?(false) }
}

// MARK: - Task row

final class TaskRowView: NSView, NSTextViewDelegate {
    let task: TaskItem
    let showsSeparator: Bool
    var onToggle: () -> Void = {}
    var onOpenLink: (URL) -> Void = { _ in }
    var onHover: ((Bool) -> Void)?
    private let circle: CircleCheckView
    private let textView: NSTextView
    private var hovering = false {
        didSet {
            wantsLayer = true
            layer?.backgroundColor = hovering ? Ink.hoverRow.cgColor : NSColor.clear.cgColor
            circle.hovering = hovering
        }
    }

    let rowHeight: CGFloat

    init(task: TaskItem, showsSeparator: Bool, ink: NSColor = Ink.ink) {
        self.task = task
        self.showsSeparator = showsSeparator
        let text = InlineHTML.nsAttributed(task.html, ink: ink, blue: Ink.blue, baseSize: 15)
        let textWidth: CGFloat = 262
        let textHeight = ceil(
            text.boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
        )
        rowHeight = max(36, textHeight + 24)

        circle = CircleCheckView(frame: .zero)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        let styled = NSMutableAttributedString(attributedString: text)
        styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: styled.length))

        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: textWidth, height: textHeight))
        textView.textStorage?.setAttributedString(styled)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        super.init(frame: .zero)
        wantsLayer = true
        textView.delegate = self
        circle.action = { [weak self] in self?.onToggle() }
        addSubview(circle)
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        circle.frame = NSRect(x: 10, y: 8, width: 28, height: 28)
        let textH = textView.frame.height
        textView.frame = NSRect(x: 48, y: (rowHeight - textH) / 2, width: textView.frame.width, height: textH)
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsSeparator {
            Ink.rowLine.setFill()
            NSRect(x: 26, y: 0, width: bounds.width - 36, height: 1).fill()
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at characterIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        onOpenLink(url)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; onHover?(false) }
}

// MARK: - Capsule content (collapsed pill)

final class CapsuleContentView: NSView {
    private let iconView = NSImageView()
    private let countLabel = NSTextField(labelWithString: "…")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "任务数")
        iconView.contentTintColor = .white.withAlphaComponent(0.92)
        countLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        countLabel.textColor = .white.withAlphaComponent(0.92)
        addSubview(iconView)
        addSubview(countLabel)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func update(count: Int, configured: Bool) {
        iconView.image = NSImage(systemSymbolName: configured ? "checkmark.circle" : "questionmark.circle", accessibilityDescription: "任务数")
        countLabel.stringValue = configured ? "\(count)" : "…"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        iconView.sizeToFit()
        countLabel.sizeToFit()
        let total = iconView.frame.width + 6 + countLabel.frame.width
        let startX = (bounds.width - total) / 2
        iconView.frame.origin = NSPoint(x: startX, y: (bounds.height - iconView.frame.height) / 2)
        countLabel.frame.origin = NSPoint(x: startX + iconView.frame.width + 6, y: (bounds.height - countLabel.frame.height) / 2)
    }
}

// MARK: - Panel content

final class PanelContentView: NSView {
    var onHeightChanged: ((CGFloat) -> Void)?
    var onOpenLink: (URL) -> Void = { _ in }
    var onHover: ((Bool) -> Void)?

    private let model: IslandModel
    private let store: TaskStore
    private var cancellables = Set<AnyCancellable>()

    private let titleLabel = NSTextField(labelWithString: "Inbox")
    private let countLabel = NSTextField(labelWithString: "0")
    private let openButton = IconButtonView(systemName: "arrow.up.forward.app", help: "在 Obsidian 中打开收件箱")
    private let optionsButton = IconButtonView(systemName: "ellipsis", help: "选项")
    private let optionsStack = NSStackView()
    private let scrollView = NSScrollView()
    private let listStack = NSStackView()
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "都处理好了")
    private let emptyHint = NSTextField(labelWithString: "新任务会自动出现在这里")
    private let loadingLabel = NSTextField(labelWithString: "正在读取收件箱…")
    private let unconfiguredTitle = NSTextField(labelWithString: "还没有选择任务笔记")
    private let unconfiguredHint = NSTextField(labelWithString: "点击 … 选择一篇 Markdown 笔记")
    private let noticeLabel = NSTextField(labelWithString: "")
    private let undoButton = ClickableLabel(labelWithString: "撤销")
    private let statusLabel = NSTextField(labelWithString: "Connecting to note…")
    private let refreshButton = IconButtonView(systemName: "arrow.clockwise", help: "刷新任务")

    private let contentWidth: CGFloat = 344
    private let headerHeight: CGFloat = 64
    private let footerBaseHeight: CGFloat = 44

    override var isFlipped: Bool { true }

    init(model: IslandModel, store: TaskStore) {
        self.model = model
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 400))
        setup()
        observe()
        rebuildAll()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    private func setup() {
        titleLabel.font = NSFont(name: "Parisienne", size: 29)
        titleLabel.textColor = Ink.ink
        countLabel.font = .systemFont(ofSize: 14)
        countLabel.textColor = Ink.muted
        statusLabel.font = {
            let base = NSFont(name: "Georgia", size: 12) ?? NSFont.systemFont(ofSize: 12, weight: .medium)
            return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        }()
        statusLabel.textColor = Ink.muted
        statusLabel.toolTip = "状态"
        emptyIcon.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "空")
        emptyIcon.contentTintColor = Ink.blue
        emptyTitle.font = .systemFont(ofSize: 17)
        emptyTitle.textColor = Ink.ink
        emptyTitle.alignment = .center
        emptyHint.font = .systemFont(ofSize: 13)
        emptyHint.textColor = Ink.muted
        emptyHint.alignment = .center
        loadingLabel.font = .systemFont(ofSize: 13)
        loadingLabel.textColor = Ink.muted
        unconfiguredTitle.font = .systemFont(ofSize: 15)
        unconfiguredTitle.textColor = Ink.ink
        unconfiguredTitle.alignment = .center
        unconfiguredHint.font = .systemFont(ofSize: 13)
        unconfiguredHint.textColor = Ink.muted
        unconfiguredHint.alignment = .center
        noticeLabel.font = .systemFont(ofSize: 12)
        noticeLabel.textColor = Ink.muted
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.maximumNumberOfLines = 2
        undoButton.font = .systemFont(ofSize: 12)
        undoButton.textColor = Ink.blue
        undoButton.wantsLayer = true
        undoButton.layer?.backgroundColor = Ink.undoBackground.cgColor
        undoButton.layer?.cornerRadius = 7
        undoButton.alignment = .center
        undoButton.toolTip = "撤销最近一次完成"

        openButton.action = { [weak self] in self?.store.openNote() }
        optionsButton.action = { [weak self] in self?.model.optionsToggled() }
        refreshButton.action = { [weak self] in self?.store.refresh() }
        undoButton.onTap = { [weak self] in self?.store.undo() }

        optionsStack.orientation = .vertical
        optionsStack.spacing = 1
        optionsStack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 8, right: 14)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = listStack
        listStack.orientation = .vertical
        listStack.spacing = 0
        listStack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 6, right: 12)
        listStack.wantsLayer = true

        addSubview(titleLabel)
        addSubview(countLabel)
        addSubview(openButton)
        addSubview(optionsButton)
        addSubview(optionsStack)
        addSubview(scrollView)
        addSubview(emptyIcon)
        addSubview(emptyTitle)
        addSubview(emptyHint)
        addSubview(loadingLabel)
        addSubview(unconfiguredTitle)
        addSubview(unconfiguredHint)
        addSubview(noticeLabel)
        addSubview(undoButton)
        addSubview(statusLabel)
        addSubview(refreshButton)
    }

    private func observe() {
        store.$tasks.receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuildAll() }.store(in: &cancellables)
        model.$showOptions.receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuildAll() }.store(in: &cancellables)
        model.$pickingFromObsidian.receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuildOptions() }.store(in: &cancellables)
        store.$notice.receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuildAll() }.store(in: &cancellables)
        store.$undoTask.receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuildAll() }.store(in: &cancellables)
        store.$statusText.receive(on: RunLoop.main).sink { [weak self] text in self?.statusLabel.stringValue = text }.store(in: &cancellables)
        store.$configured.receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuildAll() }.store(in: &cancellables)
        store.$pending.receive(on: RunLoop.main).sink { [weak self] _ in self?.updatePendingLook() }.store(in: &cancellables)
    }

    // MARK: Build

    private func rebuildAll() {
        countLabel.stringValue = "\(store.tasks.count)"
        rebuildOptions()
        rebuildList()
        rebuildFooter()
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChanged?(fittingHeight())
    }

    private func rebuildOptions() {
        optionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard model.showOptions else { return }
        func row(_ icon: String, _ label: String, destructive: Bool = false, highlight: Bool = false, action: @escaping () -> Void) {
            let view = OptionRowView(icon: icon, label: label, destructive: destructive, highlight: highlight)
            view.action = action
            optionsStack.addArrangedSubview(view)
        }
        row("arrow.clockwise", "立即刷新") { [weak self] in
            self?.store.refresh()
            self?.model.showOptions = false
        }
        row("arrow.up.forward.app", "在 Obsidian 中打开") { [weak self] in
            self?.model.showOptions = false
            self?.store.openNote()
        }
        if model.pickingFromObsidian {
            row("checkmark.circle.fill", "完成：采用 Obsidian 当前笔记", highlight: true) { [weak self] in
                self?.model.showOptions = false
                self?.model.onMenuAction(.finishObsidianPick)
            }
        } else {
            row("books.vertical", "从 Obsidian 选择当前笔记") { [weak self] in
                self?.model.onMenuAction(.startObsidianPick)
            }
        }
        row("folder", "选择文件夹（监控其中全部笔记）…") { [weak self] in
            self?.model.showOptions = false
            self?.model.onMenuAction(.pickFolder)
        }
        row(
            model.mode == .island ? "rectangle.on.rectangle" : "dot.square",
            model.mode == .island ? "切换到桌面浮窗模式" : "切换到灵动岛模式"
        ) { [weak self] in
            self?.model.showOptions = false
            self?.model.onMenuAction(.switchMode)
        }
        if model.mode == .floating {
            row("pin", model.onTop ? "取消窗口置顶" : "窗口置顶") { [weak self] in
                self?.model.showOptions = false
                self?.model.onMenuAction(.toggleOnTop)
            }
        }
        optionsStack.addArrangedSubview(makeDivider())
        row("doc.text", "选择任务笔记…") { [weak self] in
            self?.model.showOptions = false
            self?.model.onMenuAction(.pickNote)
        }
        row("power", "退出 GlassIsland", destructive: true) { [weak self] in
            self?.model.onMenuAction(.quit)
        }
        optionsStack.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalToConstant: contentWidth - 28).isActive = true }
        optionsStack.arrangedSubviews.forEach { $0.heightAnchor.constraint(equalToConstant: 30).isActive = true }
    }

    private func makeDivider() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Ink.rowLine.cgColor
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

    private func rebuildList() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if store.sourceText == nil && !store.configured {
            return
        }
        if store.sourceText == nil {
            loadingLabel.isHidden = false
            return
        }
        loadingLabel.isHidden = true
        guard !store.tasks.isEmpty else { return }
        for (index, task) in store.tasks.enumerated() {
            let row = TaskRowView(task: task, showsSeparator: index > 0)
            row.onToggle = { [weak self] in self?.store.toggle(task) }
            row.onOpenLink = { [weak self] url in self?.store.openLink(urlString: url.absoluteString) }
            row.onHover = { [weak self] hovering in
                self?.model.hoveredLine = hovering ? task.line : nil
            }
            row.widthAnchor.constraint(equalToConstant: contentWidth - 24).isActive = true
            row.heightAnchor.constraint(equalToConstant: row.rowHeight).isActive = true
            listStack.addArrangedSubview(row)
        }
    }

    private func rebuildFooter() {
        if let notice = store.notice {
            noticeLabel.stringValue = notice.text
            noticeLabel.textColor = notice.isError ? Ink.errorText : Ink.muted
        }
        undoButton.isHidden = store.undoTask == nil
        statusLabel.stringValue = store.statusText
    }

    private func updatePendingLook() {
        refreshButton.alphaValue = store.pending ? 0.55 : 1
        undoButton.alphaValue = store.pending ? 0.55 : 1
    }

    // MARK: Layout

    private var lastReportedHeight: CGFloat = -1

    override func layout() {
        super.layout()
        let width = bounds.width

        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: 22, y: 16)
        countLabel.sizeToFit()
        countLabel.frame.origin = NSPoint(x: titleLabel.frame.maxX + 8, y: 30)
        openButton.frame = NSRect(x: width - 18 - 32 - 8 - 32, y: 16, width: 32, height: 32)
        optionsButton.frame = NSRect(x: width - 18 - 32, y: 16, width: 32, height: 32)

        var y = headerHeight
        let optionsVisible = model.showOptions
        optionsStack.isHidden = !optionsVisible
        if optionsVisible {
            optionsStack.layoutSubtreeIfNeeded()
            let optionsHeight = optionsStack.fittingSize.height
            optionsStack.frame = NSRect(x: 0, y: y, width: width, height: optionsHeight)
            y += optionsHeight
        }

        let showUnconfigured = store.sourceText == nil && !store.configured
        let showLoading = store.sourceText == nil && store.configured
        let showEmpty = !(store.sourceText == nil) && store.tasks.isEmpty
        unconfiguredTitle.isHidden = !showUnconfigured
        unconfiguredHint.isHidden = !showUnconfigured
        loadingLabel.isHidden = !showLoading
        emptyIcon.isHidden = !showEmpty
        emptyTitle.isHidden = !showEmpty
        emptyHint.isHidden = !showEmpty
        scrollView.isHidden = !(store.sourceText != nil && !store.tasks.isEmpty)

        if showUnconfigured {
            unconfiguredTitle.sizeToFit()
            unconfiguredTitle.frame = NSRect(x: 0, y: y + 30, width: width, height: unconfiguredTitle.frame.height)
            unconfiguredHint.sizeToFit()
            unconfiguredHint.frame = NSRect(x: 0, y: y + 56, width: width, height: unconfiguredHint.frame.height)
            y += 110
        } else if showLoading {
            loadingLabel.frame = NSRect(x: 22, y: y + 14, width: width - 44, height: 20)
            y += 52
        } else if showEmpty {
            emptyIcon.frame = NSRect(x: (width - 40) / 2, y: y + 26, width: 40, height: 40)
            emptyTitle.sizeToFit()
            emptyTitle.frame = NSRect(x: 0, y: y + 78, width: width, height: emptyTitle.frame.height)
            emptyHint.sizeToFit()
            emptyHint.frame = NSRect(x: 0, y: y + 102, width: width, height: emptyHint.frame.height)
            y += 140
        } else {
            let listContentHeight = listStack.fittingSize.height
            let visibleListHeight = min(listContentHeight, 460)
            scrollView.frame = NSRect(x: 0, y: y, width: width, height: visibleListHeight)
            listStack.frame = NSRect(x: 0, y: 0, width: width - 24, height: listContentHeight)
            y += visibleListHeight
        }

        let noticeVisible = store.notice != nil
        noticeLabel.isHidden = !noticeVisible
        undoButton.isHidden = store.undoTask == nil || !noticeVisible
        var footerY = y
        if noticeVisible {
            noticeLabel.sizeToFit()
            noticeLabel.frame = NSRect(x: 22, y: footerY + 6, width: width - 110, height: max(18, noticeLabel.frame.height))
            undoButton.sizeToFit()
            undoButton.frame = NSRect(x: width - 16 - 52, y: footerY + 4, width: 52, height: 24)
            footerY += max(30, noticeLabel.frame.height + 10)
        }
        statusLabel.sizeToFit()
        statusLabel.frame.origin = NSPoint(x: 22, y: footerY + 8)
        refreshButton.frame = NSRect(x: width - 16 - 32, y: footerY + 4, width: 32, height: 32)

        let height = fittingHeight()
        if height != lastReportedHeight {
            lastReportedHeight = height
            onHeightChanged?(height)
        }
    }

    func fittingHeight() -> CGFloat {
        // Recomputed during layout; report the bottom-most used extent.
        var maxY: CGFloat = headerHeight
        for view in [optionsStack, scrollView, emptyIcon, emptyTitle, emptyHint, loadingLabel, unconfiguredHint, noticeLabel, statusLabel, refreshButton] {
            if !view.isHidden {
                maxY = max(maxY, view.frame.maxY)
            }
        }
        return maxY + 12
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            if model.showOptions {
                model.showOptions = false
            } else {
                model.dismiss()
            }
            return
        }
        super.keyDown(with: event)
    }
}
