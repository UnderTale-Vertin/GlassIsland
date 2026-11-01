import XCTest
@testable import GlassIsland

/// The island interaction state machine: hover reveals, click pins (and
/// expands), click again hides, and a pinned panel survives hover-out.
final class IslandModelTests: XCTestCase {
    func testHoverRevealsAndExpands() {
        let model = IslandModel(mode: .island)
        XCTAssertFalse(model.visible)
        model.hotspotEntered()
        XCTAssertTrue(model.visible)
        XCTAssertFalse(model.expanded)
        model.setHovering(true)
        XCTAssertTrue(model.expanded)
    }

    func testClickPinsExpandsAndSurvivesHoverOut() {
        let model = IslandModel(mode: .island)
        model.hotspotEntered()
        model.toggleZoneClicked()
        XCTAssertTrue(model.pinned)
        XCTAssertTrue(model.visible)
        XCTAssertTrue(model.expanded)
        // Mouse leaves the panel: a pinned panel must NOT hide.
        model.setHovering(false)
        XCTAssertTrue(model.visible, "固定后移开鼠标不应消失")
        XCTAssertTrue(model.expanded, "固定后移开鼠标不应收起")
        // And the pending-hide timer (if any) must also keep it visible.
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            if !model.visible { break }
        }
        XCTAssertTrue(model.visible, "隐藏定时器触发后固定面板仍在")
    }

    func testSecondClickHidesCompletely() {
        let model = IslandModel(mode: .island)
        model.hotspotEntered()
        model.setHovering(true)
        model.toggleZoneClicked()
        model.toggleZoneClicked()
        XCTAssertFalse(model.pinned)
        XCTAssertFalse(model.visible)
        XCTAssertFalse(model.expanded)
    }

    func testUnpinnedHoverOutSchedulesHide() {
        let model = IslandModel(mode: .island)
        model.hotspotEntered()
        model.setHovering(true)
        model.setHovering(false)
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline && model.visible {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(model.visible, "未固定时移开鼠标应自动收回")
        XCTAssertFalse(model.expanded)
    }

    func testToggleZoneIgnoredInFloatingMode() {
        let model = IslandModel(mode: .floating)
        XCTAssertTrue(model.visible && model.expanded)
        // Clicking the zone in floating mode must not hide the window.
        model.toggleZoneClicked()
        XCTAssertTrue(model.visible)
        XCTAssertTrue(model.expanded)
    }
}
