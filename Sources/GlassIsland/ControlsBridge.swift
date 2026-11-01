import AppKit
import SwiftUI

/// Bridges SwiftUI-rendered controls to AppKit click targets. SwiftUI tap
/// gestures proved unreliable inside this glass panel, so SwiftUI only
/// *renders and reports geometry*; every action fires through AppKit
/// mouseDown here — the mechanism proven to work (toggle zone).
final class IslandControlBridge {
    static let shared = IslandControlBridge()

    weak var model: IslandModel?
    private var actions: [String: () -> Void] = [:]

    func setAction(_ id: String, _ action: @escaping () -> Void) {
        actions[id] = action
    }

    func fire(_ id: String) {
        DiagLog.log("action \(id)")
        guard let action = actions[id] else {
            DiagLog.log("NO-ACTION registered for \(id)")
            return
        }
        action()
    }
}

/// Invisible AppKit button layered above a SwiftUI-rendered control.
final class OverlayButton: NSView {
    let controlID: String
    /// Optional hover mirroring (used by task circles to keep the highlight).
    var onHover: ((Bool) -> Void)?

    init(controlID: String) {
        self.controlID = controlID
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func mouseDown(with event: NSEvent) {
        DispatchQueue.main.async { [controlID] in
            IslandControlBridge.shared.fire(controlID)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Dynamic dispatch goes through IslandControlBridge.fire (registry).

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        guard onHover != nil else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// Full-panel container: transparent to clicks except where OverlayButton
/// children sit, so scrolling and hover keep working underneath.
final class ControlsOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return (hit === self || hit == nil) ? nil : hit
    }
}
