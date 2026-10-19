import XCTest

final class PointingFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testAxisSwitchChangesPhysicalDirection() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screenshot-radar-top-aligned"]
        app.launch()
        let status = app.staticTexts["pointingStatus"]
        XCTAssertTrue(status.waitForExistence(timeout:10))
        XCTAssertEqual(status.label,"НАПРАВЛЕНИЕ СОВПАЛО")
        app.segmentedControls["aimAxis"].buttons["Заднее стекло"].tap()
        expectation(for:NSPredicate(format:"label != %@","НАПРАВЛЕНИЕ СОВПАЛО"),evaluatedWith:status)
        waitForExpectations(timeout:5)
        app.segmentedControls["aimAxis"].buttons["Верхняя грань"].tap()
        expectation(for:NSPredicate(format:"label == %@","НАПРАВЛЕНИЕ СОВПАЛО"),evaluatedWith:status)
        waitForExpectations(timeout:5)
    }
    func testEarthMenuAndBackGlassInstructions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screenshot-radar-back-aligned"]
        app.launch()
        XCTAssertTrue(app.buttons["showEarth"].waitForExistence(timeout:10))
        app.buttons["showEarth"].tap()
        XCTAssertTrue(app.buttons["earthPasses"].waitForExistence(timeout:5))
        app.buttons["earthPasses"].tap()
        XCTAssertTrue(app.navigationBars["Пролёты"].waitForExistence(timeout:5))
        app.buttons["Готово"].tap()
        app.buttons["earthIntro"].tap()
        XCTAssertTrue(app.staticTexts["introTitle"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["introTitle"].label.contains("Заднее стекло"))
        app.buttons["continuePointing"].tap()
        XCTAssertTrue(app.buttons["finishPointing"].waitForExistence(timeout:5))
        app.buttons["finishPointing"].tap()
        XCTAssertTrue(app.buttons["startPointing"].waitForExistence(timeout:5))
    }
    func testCatalogueHasSessionsForEverySatellite() {
        let app=XCUIApplication(); app.launchArguments=["--ui-screenshot-catalogue"]; app.launch()
        let iss=app.descendants(matching:.any)["session-25544"]
        XCTAssertTrue(iss.waitForExistence(timeout:15))
        XCTAssertTrue(app.buttons["satellite-59112"].exists)
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching:.any)["session-62394"].exists)
    }
    func testOrbitTimeScrubbingAndReturnToLive() {
        let app=XCUIApplication(); app.launchArguments=["--ui-screenshot-orbits"]; app.launch()
        let timeline=app.sliders["orbitTimeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout:15))
        XCTAssertTrue(app.descendants(matching:.any)["orbitCoordinates"].waitForExistence(timeout:15))
        timeline.adjust(toNormalizedSliderPosition:0.25)
        let mode=app.descendants(matching:.any)["orbitTimeMode"]
        XCTAssertTrue(mode.label.contains("ПРОГНОЗ"))
        app.buttons["playOrbit"].tap()
        XCTAssertEqual(app.buttons["playOrbit"].label,"Пауза")
        app.buttons["playOrbit"].tap()
        app.buttons["toggleAllSatellites"].tap()
        app.buttons["toggleGroundTrack"].tap()
        app.buttons["focusOrbit"].tap()
        app.buttons["orbitNow"].tap()
        XCTAssertTrue(mode.label.contains("СЕЙЧАС"))
        app.buttons["closeOrbits"].tap()
        XCTAssertTrue(app.buttons["startPointing"].waitForExistence(timeout:5))
    }
}
