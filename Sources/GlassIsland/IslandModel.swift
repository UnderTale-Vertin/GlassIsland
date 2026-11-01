import Foundation
import Combine

/// Window/UI phase state. Nothing is visible by default: an invisible
/// hotspot strip along the top edge of the screen reveals the pill, hover
/// expands it, and moving away hides it completely.
final class IslandModel: ObservableObject {
    enum MenuAction {
        case toggleOnTop
        case switchMode
        case refresh
        case openNote
        case pickNote
        case pickFolder
        case startObsidianPick
        case finishObsidianPick
        case quit
    }

    @Published var visible = false
    @Published var expanded = false
    @Published var pinned = false
    @Published var mode: IslandMode
    /// Inline options section (replaces popup menus, which cannot open in a
    /// non-activating panel).
    @Published var showOptions = false
    /// "从 Obsidian 选择当前笔记" flow in progress.
    @Published var pickingFromObsidian = false
    /// Window-pinning state for floating mode (kept in Config, mirrored here).
    @Published var onTop = false
    /// Highlighted row (hover) for the circle tint.
    @Published var hoveredLine: String?
    /// Frames of interactive elements in panel space (top-left origin),
    /// reported by SwiftUI; the AppKit overlay places real click targets.
    @Published var controlFrames: [String: CGRect] = [:]

    var onMenuAction: (MenuAction) -> Void = { _ in }

    private var hideWork: DispatchWorkItem?

    init(mode: IslandMode) {
        self.mode = mode
        if mode == .floating {
            visible = true
            expanded = true
        }
    }

    /// Mouse touched the invisible strip at the very top edge of the screen.
    func hotspotEntered() {
        guard mode == .island else { return }
        hideWork?.cancel()
        hideWork = nil
        visible = true
    }

    func setHovering(_ hovering: Bool) {
        if hovering {
            hideWork?.cancel()
            hideWork = nil
            if mode == .island {
                visible = true
                expanded = true
            }
        } else {
            guard mode == .island, !pinned else { return }
            scheduleHide(after: 0.32)
        }
    }

    /// "…" button or right-click: open the inline options section.
    func optionsToggled() {
        if showOptions {
            showOptions = false
            return
        }
        hideWork?.cancel()
        hideWork = nil
        visible = true
        expanded = true
        showOptions = true
    }

    /// Click on the toggle zone (capsule body / panel title area, an AppKit
    /// view — not a SwiftUI gesture): first click pins and expands, the next
    /// click hides everything. Floating mode ignores it.
    func toggleZoneClicked() {
        guard mode == .island else { return }
        hideWork?.cancel()
        hideWork = nil
        if pinned {
            dismiss()
        } else {
            pinned = true
            visible = true
            expanded = true
            showOptions = false
        }
    }

    func reportFrame(_ id: String, _ frame: CGRect) {
        if controlFrames[id] != frame {
            controlFrames[id] = frame
        }
    }

    func togglePin() {
        pinned.toggle()
        if pinned {
            visible = true
            expanded = true
            hideWork?.cancel()
            hideWork = nil
        } else if mode == .island {
            scheduleHide(after: 0.32)
        }
    }

    /// Esc or outside click: hide everything.
    func dismiss() {
        pinned = false
        showOptions = false
        hideWork?.cancel()
        hideWork = nil
        if mode == .island {
            expanded = false
            visible = false
        }
    }

    func setMode(_ newMode: IslandMode) {
        guard newMode != mode else { return }
        mode = newMode
        hideWork?.cancel()
        hideWork = nil
        pinned = false
        showOptions = false
        visible = (newMode == .floating)
        expanded = (newMode == .floating)
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pinned else { return }
            self.expanded = false
            self.visible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        hideWork = work
    }
}
