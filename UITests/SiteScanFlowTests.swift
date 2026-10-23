import XCTest

final class SiteScanFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testWeatherIsOptionalAndScannerClosesAfterOpeningConditions() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-site-scan"]; app.launch()
        XCTAssertTrue(app.buttons["closeSiteScan"].waitForExistence(timeout:10))
        let conditions = app.buttons["siteWeatherDisclosure"]
        for _ in 0..<5 where !conditions.isHittable { app.swipeUp() }
        XCTAssertTrue(conditions.isHittable)
        conditions.tap()
        let load = app.buttons["loadSiteWeather"]
        for _ in 0..<3 where !load.isHittable { app.swipeUp() }
        XCTAssertTrue(load.isHittable)
        XCTAssertTrue(load.isEnabled)
        let screenshot = XCTAttachment(screenshot:app.screenshot())
        screenshot.name = "weather-controls"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["closeSiteScan"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
    }
    func testScannerCanOpenAndCloseWithoutStartingCamera() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-home"]; app.launch()
        let open = app.buttons["openSiteScan"]
        XCTAssertTrue(open.waitForExistence(timeout:10))
        if !open.isHittable { app.swipeUp() }
        open.tap()
        XCTAssertTrue(app.buttons["startSiteScan"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["scanStatus"].exists)
        app.buttons["closeSiteScan"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["closeSiteScan"].exists)
    }
    func testScannerPreviewNeverClaimsRadioConnectionAndCanClose() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-site-scan"]; app.launch()
        XCTAssertTrue(app.buttons["closeSiteScan"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["Пример карты · не результат измерения"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["siteAssessment"].waitForExistence(timeout:5))
        XCTAssertEqual(app.staticTexts["siteAssessment"].label,"На пути есть препятствия")
        app.buttons["closeSiteScan"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
    }
    func testAutoToggleAndDateLabelExist() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-home"]; app.launch()
        let auto = app.switches["autoSelectSatellite"]
        XCTAssertTrue(auto.waitForExistence(timeout:15))
        if !auto.isHittable { app.swipeUp() }
        let before = auto.value as? String
        auto.tap()
        XCTAssertNotEqual(auto.value as? String,before)
        auto.tap()
        app.swipeDown()
        app.buttons["openSettings"].tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout:5))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Дата"].exists)
        XCTAssertFalse(app.staticTexts["Эпоха"].exists)
    }
}
