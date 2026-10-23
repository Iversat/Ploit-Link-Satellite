import XCTest

final class SiteScanFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testWeatherIsOptionalAndScannerClosesAfterOpeningConditions() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-site-scan"]; app.launch()
        XCTAssertTrue(app.buttons["closeSiteScan"].waitForExistence(timeout:10))
        let scroll = app.scrollViews.firstMatch
        let conditions = app.buttons["siteWeatherDisclosure"]
        for _ in 0..<5 where !conditions.isHittable {
            scroll.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:0.80))
                .press(forDuration:0.05,thenDragTo:scroll.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:0.45)))
        }
        XCTAssertTrue(conditions.isHittable)
        conditions.tap()
        let load = app.buttons["loadSiteWeather"]
        for _ in 0..<3 where !load.isHittable {
            scroll.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:0.80))
                .press(forDuration:0.05,thenDragTo:scroll.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:0.45)))
        }
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
        let scroll = app.scrollViews.firstMatch
        scroll.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:0.80))
            .press(forDuration:0.05,thenDragTo:scroll.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:0.45)))
        XCTAssertTrue(app.staticTexts["siteAssessment"].waitForExistence(timeout:5))
        XCTAssertEqual(app.staticTexts["siteAssessment"].label,"На пути есть препятствия")
        app.buttons["closeSiteScan"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
    }
    func testSkyDomeRotatesInBothDirectionsResetsAndReturnsHome() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-site-scan"]; app.launch()
        let close = app.buttons["closeSiteScan"]
        XCTAssertTrue(close.waitForExistence(timeout:10))
        let dome = app.descendants(matching:.any).matching(identifier:"skyDome").firstMatch
        let scroll = app.scrollViews.firstMatch
        let top = close.frame.maxY + 8
        let bottom = app.windows.firstMatch.frame.maxY - 24
        for _ in 0..<5 {
            if dome.exists && dome.frame.minY >= top && dome.frame.maxY <= bottom { break }
            let moveDown = dome.exists && dome.frame.minY < top
            // Scroll in the outer gutter so the globe's pan recognizer does not consume the gesture.
            scroll.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:moveDown ? 0.30:0.80))
                .press(forDuration:0.05,thenDragTo:scroll.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:moveDown ? 0.65:0.45)))
        }
        XCTAssertTrue(dome.isHittable)
        XCTAssertGreaterThanOrEqual(dome.frame.minY,top)
        XCTAssertLessThanOrEqual(dome.frame.maxY,bottom)
        let initial = try XCTUnwrap(dome.value as? String)
        XCTAssertFalse(initial.isEmpty)
        let before = XCTAttachment(screenshot:app.screenshot())
        before.name = "sky-dome"; before.lifetime = .keepAlways; add(before)

        dome.coordinate(withNormalizedOffset:CGVector(dx:0.75,dy:0.50))
            .press(forDuration:0.05,thenDragTo:dome.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.50)))
        let horizontal = try XCTUnwrap(dome.value as? String)
        XCTAssertNotEqual(horizontal,initial,"Horizontal drag must rotate the dome.")
        dome.coordinate(withNormalizedOffset:CGVector(dx:0.50,dy:0.70))
            .press(forDuration:0.05,thenDragTo:dome.coordinate(withNormalizedOffset:CGVector(dx:0.50,dy:0.30)))
        XCTAssertNotEqual(dome.value as? String,horizontal,"Vertical drag must tilt the dome.")
        // Let the compositor finish the surrounding glass and text before capturing the rotated frame.
        let composited = expectation(description:"Rotated dome frame composited")
        DispatchQueue.main.asyncAfter(deadline:.now() + 0.5) { composited.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for:[composited],timeout:2),.completed)
        let rotated = XCTAttachment(screenshot:app.screenshot())
        rotated.name = "sky-dome-rotated"; rotated.lifetime = .keepAlways; add(rotated)
        let rotatedScreen = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        rotatedScreen.name = "sky-dome-rotated-screen"; rotatedScreen.lifetime = .keepAlways; add(rotatedScreen)

        let reset = app.buttons["resetSkyDome"]
        XCTAssertTrue(reset.isHittable)
        reset.tap()
        XCTAssertEqual(dome.value as? String,initial,"Reset must restore the original viewing angles.")
        let resetScreen = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        resetScreen.name = "sky-dome-reset-screen"; resetScreen.lifetime = .keepAlways; add(resetScreen)
        close.tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
        XCTAssertFalse(close.exists)
    }
    func testAutoToggleAndDateLabelExist() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-home"]; app.launch()
        let auto = app.switches["autoSelectSatellite"]
        XCTAssertTrue(auto.waitForExistence(timeout:15))
        // The preview uses real dated TLEs: wait for the async recommendation, or its settled stale-data result.
        if !app.staticTexts["recommendedSession"].waitForExistence(timeout:20) {
            let unavailable = app.staticTexts["recommendationUnavailable"]
            let settled = expectation(for:NSPredicate(format:"exists == true AND label == %@","Нет подходящих окон по актуальным данным"),evaluatedWith:unavailable)
            XCTAssertEqual(XCTWaiter.wait(for:[settled],timeout:5),.completed)
        }
        if !auto.isHittable { app.swipeUp() }

        func waitForStableToggle() {
            var previous: CGRect?
            var unchangedSince = Date()
            let stable = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
                guard auto.exists, auto.isHittable else { previous=nil; return false }
                let frame = auto.frame
                guard frame.width > 0, frame.height > 0 else { return false }
                if previous != frame { previous=frame; unchangedSince=Date(); return false }
                return Date().timeIntervalSince(unchangedSince) >= 1
            },object:nil)
            XCTAssertEqual(XCTWaiter.wait(for:[stable],timeout:10),.completed,"Toggle geometry must settle before a single tap.")
        }
        waitForStableToggle()
        let before = try XCTUnwrap(auto.value as? String)
        XCTAssertTrue(["0","1"].contains(before))
        let toggled = before == "1" ? "0":"1"
        auto.tap()
        let changed = expectation(for:NSPredicate(format:"value == %@",toggled),evaluatedWith:auto)
        XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:5),.completed,"One tap must change the switch value.")
        waitForStableToggle()
        auto.tap()
        let restored = expectation(for:NSPredicate(format:"value == %@",before),evaluatedWith:auto)
        XCTAssertEqual(XCTWaiter.wait(for:[restored],timeout:5),.completed,"The second tap must restore the switch value.")
        app.swipeDown()
        app.buttons["openSettings"].tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout:5))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Дата"].exists)
        XCTAssertFalse(app.staticTexts["Эпоха"].exists)
    }
}
