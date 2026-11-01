import AppKit
import SwiftUI
import Combine

/// Borderless non-activating panel that can become key (so Esc, tooltips and
/// text interaction work inside).
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Hosting view that NEVER takes clicks — the glass background is purely
/// visual; all interaction lives in the AppKit content view above it.
final class PassthroughHostingView: NSHostingView<GlassBackgroundView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Invisible strip along the top edge of the screen. Hovering it reveals the
/// island; it never draws anything.
final class HotspotView: NSView {
    var onEnter: () -> Void = {}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        DispatchQueue.main.async { self.onEnter() }
    }
}

/// AppKit click zone over the capsule/panel title area. hitTest verifies the
/// point itself because NSHostingView asks subviews without a pre-check.
final class ToggleZoneView: NSView {
    var onToggle: () -> Void = {}
    var onContextMenu: () -> Void = {}
    var onHover: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        DispatchQueue.main.async { self.onToggle() }
    }
    override func rightMouseDown(with event: NSEvent) {
        DispatchQueue.main.async { self.onContextMenu() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// Owns the island window: passive glass background hosting, the AppKit
/// panel content, the title click zone and the top-edge hotspot.
final class IslandController: NSObject, NSWindowDelegate {
    let panel: IslandPanel
    let model: IslandModel
    let store: TaskStore

    private var configProvider: () -> Config
    private var backgroundHosting: PassthroughHostingView!
    private var contentView: NSView!
    private var panelContent: PanelContentView!
    private var capsuleContent: CapsuleContentView!
    private var cancellables = Set<AnyCancellable>()

    private let hotspotPanel: NSPanel
    private let hotspotView: HotspotView
    private let toggleZoneView = ToggleZoneView(frame: .zero)

    init(model: IslandModel, store: TaskStore, configProvider: @escaping () -> Config) {
        self.model = model
        self.store = store
        self.configProvider = configProvider
        self.panel = IslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 344, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.hotspotPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 6),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.hotspotView = HotspotView(frame: NSRect(x: 0, y: 0, width: 400, height: 6))
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self

        hotspotPanel.isOpaque = false
        hotspotPanel.backgroundColor = .clear
        hotspotPanel.hasShadow = false
        hotspotPanel.level = .floating
        hotspotPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hotspotPanel.isReleasedWhenClosed = false
        hotspotPanel.hidesOnDeactivate = false
        hotspotView.onEnter = { [weak self] in self?.model.hotspotEntered() }
        hotspotPanel.contentView = hotspotView

        // Root: glass background below, AppKit content above, click zone top.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 344, height: 40))
        root.wantsLayer = true
        root.layer?.cornerRadius = 17
        root.layer?.masksToBounds = true
        root.layer?.isOpaque = false
        root.layer?.backgroundColor = NSColor.clear.cgColor

        backgroundHosting = PassthroughHostingView(rootView: GlassBackgroundView(model: model))
        backgroundHosting.frame = root.bounds
        backgroundHosting.autoresizingMask = [.width, .height]
        root.addSubview(backgroundHosting)

        panelContent = PanelContentView(model: model, store: store)
        panelContent.frame = root.bounds
        panelContent.autoresizingMask = [.width, .height]
        root.addSubview(panelContent)

        capsuleContent = CapsuleContentView(frame: NSRect(x: 0, y: 0, width: 344, height: 34))
        root.addSubview(capsuleContent)

        toggleZoneView.onToggle = { [weak self] in self?.handleToggleZone() }
        toggleZoneView.onContextMenu = { [weak self] in self?.model.optionsToggled() }
        toggleZoneView.toolTip = "点一下固定；再点一下消失；右键选项"
        root.addSubview(toggleZoneView)

        panel.contentView = root
        contentView = root

        model.$contentHeight
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refit() }
            .store(in: &cancellables)

        // The show/hide switch for the whole island.
        model.$visible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                guard let self else { return }
                if visible {
                    self.refit()
                    self.panel.orderFrontRegardless()
                } else {
                    self.panel.orderOut(nil)
                }
            }
            .store(in: &cancellables)

        toggleZoneView.onHover = { [weak self] hovering in
            guard let self else { return }
            if hovering {
                self.model.setHovering(true)
            } else if !self.model.expanded {
                // Leaving the untouched capsule hides it again; when the
                // panel is open the full-panel tracker owns the exit.
                self.model.setHovering(false)
            }
        }

        panelContent.onHover = { [weak self] hovering in
            self?.model.setHovering(hovering)
        }

        store.$tasks.receive(on: RunLoop.main).sink { [weak self] tasks in
            self?.capsuleContent.update(count: tasks.count, configured: self?.store.configured ?? false)
        }.store(in: &cancellables)
        store.$configured.receive(on: RunLoop.main).sink { [weak self] configured in
            self?.capsuleContent.update(count: self?.store.tasks.count ?? 0, configured: configured)
        }.store(in: &cancellables)

        model.$expanded.combineLatest(model.$mode)
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded, mode in
                self?.phaseChanged(expanded: expanded, mode: mode)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    func show() {
        positionHotspot()
        hotspotPanel.orderFrontRegardless()
        phaseChanged(expanded: model.expanded, mode: model.mode)
        if model.mode == .floating {
            refit()
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Layout

    private func handleToggleZone() {
        DiagLog.log("toggleZone click pinned=\(model.pinned) expanded=\(model.expanded) visible=\(model.visible)")
        model.toggleZoneClicked()
    }

    private func targetScreen() -> NSScreen? {
        if let builtin = NSScreen.screens.first(where: { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }) {
            return builtin
        }
        return NSScreen.screens.first
    }

    @objc private func screenChanged() {
        positionHotspot()
        if model.mode == .island {
            refit()
        }
    }

    private func positionHotspot() {
        guard let screen = targetScreen() else { return }
        let size = hotspotPanel.frame.size
        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        hotspotPanel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// Sizes the window to the reported content height. Island frames anchor
    /// to the top center just below the menu bar.
    private func refit() {
        let expanded = model.expanded
        let width: CGFloat = expanded ? 344 : 90
        let height: CGFloat = expanded ? max(model.contentHeight, 120) : 34

        // Sync the visible content with the phase.
        panelContent.isHidden = !expanded
        capsuleContent.isHidden = expanded
        if expanded {
            capsuleContent.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        } else {
            capsuleContent.frame = NSRect(x: (width - 90) / 2, y: 0, width: 90, height: 34)
        }
        contentView.layer?.cornerRadius = expanded ? 28 : 17
        if !expanded {
            toggleZoneView.frame = NSRect(x: 0, y: 0, width: 90, height: 34)
        } else {
            toggleZoneView.frame = NSRect(x: 12, y: 4, width: 150, height: 56)
        }

        if model.mode == .island {
            if shrinking { return }
            guard let screen = targetScreen() else { return }
            let top = screen.visibleFrame.maxY
            let origin = CGPoint(
                x: screen.visibleFrame.midX - width / 2,
                y: top - height
            )
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        } else {
            let old = panel.frame
            let origin: CGPoint
            let cfg = configProvider()
            if let x = cfg.floatingOriginX, let y = cfg.floatingOriginY, old.width == width, old.height == height {
                origin = CGPoint(x: x, y: y)
            } else {
                origin = CGPoint(x: old.minX, y: old.maxY - height)
            }
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        }
    }

    private var shrinking = false

    private func phaseChanged(expanded: Bool, mode: IslandMode) {
        let isIsland = mode == .island
        panel.hasShadow = !isIsland || expanded
        panel.isMovableByWindowBackground = !isIsland
        panel.level = isIsland ? .statusBar : (configProvider().pinnedOnTop ? .statusBar : .floating)
        if isIsland {
            if expanded {
                shrinking = false
                refit()
            } else {
                guard !shrinking else { return }
                shrinking = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                    guard let self else { return }
                    self.shrinking = false
                    self.refit()
                }
            }
        } else {
            shrinking = false
            refit()
        }
    }

    // MARK: - Mode and level changes (called from AppDelegate)

    func refitForLevelChange() {
        phaseChanged(expanded: model.expanded, mode: model.mode)
    }

    func applyModeChange(_ mode: IslandMode) {
        if mode == .floating {
            let cfg = configProvider()
            if let x = cfg.floatingOriginX, let y = cfg.floatingOriginY {
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            } else if let screen = NSScreen.screens.first {
                let size = panel.frame.size
                panel.setFrameOrigin(NSPoint(
                    x: screen.visibleFrame.midX - size.width / 2,
                    y: screen.visibleFrame.midY - size.height / 2
                ))
            }
            panel.makeKeyAndOrderFront(nil)
        }
        phaseChanged(expanded: model.expanded, mode: model.mode)
        refit()
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard model.mode == .floating else { return }
        var cfg = configProvider()
        cfg.floatingOriginX = panel.frame.origin.x
        cfg.floatingOriginY = panel.frame.origin.y
        cfg.save()
    }
}
