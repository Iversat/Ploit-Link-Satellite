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
}
