import AppKit
import SwiftUI
import Combine

/// Borderless non-activating panel that can become key (so SwiftUI menus,
/// hover and Esc work inside the glass panel).
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Invisible strip along the top edge of the screen. Hovering it reveals the
/// island; it never draws anything and sits below the menu bar level.
final class HotspotView: NSView {
    var onEnter: () -> Void = {}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }
    override func mouseEntered(with event: NSEvent) {
        DispatchQueue.main.async { self.onEnter() }
    }
}

/// AppKit click zone layered over the capsule/panel title area. SwiftUI tap
/// gestures proved unreliable here (ScrollView swallows container taps), so
/// pin/hide is driven by this view's mouseDown — a framework-level callback
/// that cannot be swallowed.
final class ToggleZoneView: NSView {
    var onToggle: () -> Void = {}
    var onContextMenu: () -> Void = {}
    override func mouseDown(with event: NSEvent) {
        DispatchQueue.main.async { self.onToggle() }
    }
    override func rightMouseDown(with event: NSEvent) {
        DispatchQueue.main.async { self.onContextMenu() }
    }
    // NSHostingView asks subviews without a containment pre-check, so this
    // MUST verify the point itself — returning self unconditionally would
    // swallow every click in the panel.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the island NSPanel and the top-edge hotspot. The island window is
/// hidden until revealed; it draws below the menu bar (floating level), never
/// on top of it.
final class IslandController: NSObject, NSWindowDelegate {
    let panel: IslandPanel
    let model: IslandModel
    let store: TaskStore

    private var configProvider: () -> Config
    private var hosting: NSHostingView<IslandRootView>!
    private var sizeObservation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    private var shrinking = false

    private let hotspotPanel: NSPanel
    private let hotspotView: HotspotView
    private let toggleZoneView = ToggleZoneView(frame: .zero)
    private let controlsOverlay = ControlsOverlayView(frame: .zero)

    init(model: IslandModel, store: TaskStore, configProvider: @escaping () -> Config) {
        self.model = model
        self.store = store
        self.configProvider = configProvider
        self.panel = IslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 40),
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
        panel.level = .floating
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
        hotspotPanel.ignoresMouseEvents = false
        hotspotView.onEnter = { [weak self] in self?.model.hotspotEntered() }
        hotspotPanel.contentView = hotspotView

        hosting = NSHostingView(rootView: IslandRootView(model: model, store: store))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        applyWindowMask()
        toggleZoneView.onToggle = { [weak self] in self?.handleToggleZone() }
        toggleZoneView.onContextMenu = { [weak self] in
            self?.model.optionsToggled()
        }
        toggleZoneView.toolTip = "点一下固定；再点一下消失；右键选项"
        hosting.addSubview(controlsOverlay)
        hosting.addSubview(toggleZoneView)
        IslandControlBridge.shared.model = model
        DiagLog.log("hosting flipped=\(hosting.isFlipped)")
        model.$controlFrames
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncControls() }
            .store(in: &cancellables)
        startClickAudit()
        sizeObservation = hosting.observe(\.intrinsicContentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refit()
                self?.layoutToggleZone()
            }
        }

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

    /// Places invisible AppKit buttons over the frames SwiftUI reported and
    /// (re)binds their actions. Runs whenever frames or panel size change.
    private func syncControls() {
        controlsOverlay.frame = hosting.bounds
        let frames = model.controlFrames
        // Drop stale buttons; the frames dictionary is the source of truth.
        for sub in controlsOverlay.subviews {
            if let button = sub as? OverlayButton, frames[button.controlID] == nil {
                sub.removeFromSuperview()
            }
        }
        for (id, swiftFrame) in frames {
            var frame = swiftFrame
            if frame.width < 8 || frame.height < 8 { continue }
            // Hosting view is flipped: SwiftUI panel-space frames (top-left
            // origin) map 1:1 onto AppKit frames — no vertical mirroring.
            let button: OverlayButton
            if let existing = controlsOverlay.subviews.first(where: { ($0 as? OverlayButton)?.controlID == id }) as? OverlayButton {
                button = existing
            } else {
                button = OverlayButton(controlID: id)
                bindAction(button)
                controlsOverlay.addSubview(button)
                DiagLog.log("control added \(id)")
            }
            if button.frame != frame {
                button.frame = frame
            }
        }
        let count = controlsOverlay.subviews.count
        if count != lastControlCount {
            lastControlCount = count
            DiagLog.log("controls synced: \(count) [\(controlsOverlay.subviews.compactMap { ($0 as? OverlayButton)?.controlID }.joined(separator: ", "))]")
        }
    }

    private var lastControlCount = -1

    private func bindAction(_ button: OverlayButton) {
        let bridge = IslandControlBridge.shared
        switch button.controlID {
        case "ctrl:open":
            bridge.setAction(button.controlID) { [weak self] in self?.store.openNote() }
        case "ctrl:options":
            bridge.setAction(button.controlID) { [weak self] in self?.model.optionsToggled() }
        case "ctrl:undo":
            bridge.setAction(button.controlID) { [weak self] in
                guard let self, !self.store.pending else { return }
                self.store.undo()
            }
        case "ctrl:refresh":
            bridge.setAction(button.controlID) { [weak self] in self?.store.refresh() }
        default:
            if button.controlID.hasPrefix("circle:") {
                let controlID = button.controlID
                bridge.setAction(controlID) { [weak self] in
                    guard let self,
                          let task = self.store.tasks.first(where: { "circle:\($0.id)" == controlID }) else { return }
                    self.store.toggle(task)
                }
                button.onHover = { [weak self] hovering in
                    guard let self,
                          let task = self.store.tasks.first(where: { "circle:\($0.id)" == controlID }) else { return }
                    self.model.hoveredLine = hovering ? task.line : nil
                }
            }
            // "option:<label>" actions are registered by the SwiftUI rows.
        }
    }

    /// Always-on click audit for feature verification (diag.log).
    private func startClickAudit() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window === self.panel {
                DiagLog.log("raw click \(NSStringFromPoint(event.locationInWindow))")
            }
            return event
        }
    }

    /// Positions the AppKit click zone over the capsule/panel title area.
    /// NSHostingView is FLIPPED (origin top-left), so y=4 means 4pt from the
    /// top — the title row.
    private func layoutToggleZone() {
        let bounds = hosting.bounds
        toggleZoneView.frame = NSRect(x: 12, y: 4, width: 150, height: 62)
        _ = bounds
    }

    /// Clips the window content to the glass shape so nothing (hosting layer
    /// background, glass overflow) can paint black into the corner gaps.
    private func applyWindowMask() {
        guard let content = panel.contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = model.expanded ? 28 : 17
        content.layer?.masksToBounds = true
        content.layer?.isOpaque = false
        content.layer?.backgroundColor = NSColor.clear.cgColor
        layoutToggleZone()
    }

    private func targetScreen() -> NSScreen? {
        // Prefer the built-in (notched) display.
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

    /// Sizes the window to the SwiftUI ideal size. In island mode the frame is
    /// anchored to the top center just below the menu bar; the glass morph
    /// happens inside SwiftUI while the window is already at its final size.
    private func refit() {
        let size = hosting.intrinsicContentSize
        if ProcessInfo.processInfo.environment["GLASSISLAND_LOG"] == "1" {
            NSLog("REFIT intrinsic=%@ expanded=%d mode=%@ shrinking=%d",
                  NSStringFromSize(size), model.expanded ? 1 : 0, model.mode.rawValue, shrinking ? 1 : 0)
        }
        guard size.width > 1, size.height > 1 else { return }
        defer {
            layoutToggleZone()
            syncControls()
        }
        if model.mode == .island {
            // While collapsing, keep the window large until the morph ends.
            if shrinking { return }
            guard let screen = targetScreen() else { return }
            let top = screen.visibleFrame.maxY
            let origin = CGPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: top - size.height
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        } else {
            let old = panel.frame
            let origin: CGPoint
            let cfg = configProvider()
            if let x = cfg.floatingOriginX, let y = cfg.floatingOriginY, old.width == size.width, old.height == size.height {
                origin = CGPoint(x: x, y: y)
            } else {
                origin = CGPoint(x: old.minX, y: old.maxY - size.height)
            }
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        }
    }

    private func phaseChanged(expanded: Bool, mode: IslandMode) {
        let isIsland = mode == .island
        panel.hasShadow = !isIsland || expanded
        panel.isMovableByWindowBackground = !isIsland
        panel.level = isIsland ? .statusBar : (configProvider().pinnedOnTop ? .statusBar : .floating)
        toggleZoneView.isHidden = !isIsland
        applyWindowMask()
        if isIsland {
            if expanded {
                shrinking = false
                refit()
            } else {
                // Let the collapse morph finish before shrinking the window.
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

    /// Called when window level settings change (pin toggle).
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
