import XCTest

final class SiteScanFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testRoomScanShowsDotsAndPercentageBelowHorizon() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-site-capture-room"]; app.launch()
        XCTAssertTrue(app.staticTexts["scanCoverage"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["ОСМОТРИТЕ СТЕНЫ, ОКНА И ПОТОЛОК"].exists)
        XCTAssertFalse(app.staticTexts["НАПРАВЬТЕ КАМЕРУ В НЕБО"].exists)
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"skyCaptureDots").firstMatch.exists)
        app.buttons["finishSiteScan"].tap()
        XCTAssertTrue(app.segmentedControls["skyViewMode"].waitForExistence(timeout:5))
        app.buttons["closeSiteScan"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
    }
    func testSkyModesPathAndNeutralInformationReturnToMap() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-site-scan"]; app.launch()
        XCTAssertTrue(app.buttons["closeSiteScan"].waitForExistence(timeout:10))
        let mode = app.segmentedControls["skyViewMode"]
        let scroll = app.scrollViews.firstMatch
        func reveal(_ element:XCUIElement) {
            for _ in 0..<5 where !element.isHittable {
                scroll.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:0.80))
                    .press(forDuration:0.05,thenDragTo:scroll.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:0.45)))
            }
            XCTAssertTrue(element.isHittable)
        }
        reveal(mode)
        mode.buttons["Гироскоп"].tap()
        XCTAssertTrue(mode.buttons["Гироскоп"].isSelected)
        mode.buttons["От точки старта"].tap()
        XCTAssertTrue(mode.buttons["От точки старта"].isSelected)
        let path = app.buttons["toggleSkyPassPath"]
        reveal(path)
        XCTAssertEqual(path.value as? String,"Скрыт")
        path.tap()
        XCTAssertEqual(path.value as? String,"Показан")
        app.buttons["siteScanInformation"].tap()
        XCTAssertTrue(app.staticTexts["Что означает процент"].waitForExistence(timeout:5))
        let screenshot = XCTAttachment(screenshot:app.screenshot())
        screenshot.name = "sky-information"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Готово"].tap()
        XCTAssertTrue(app.buttons["closeSiteScan"].waitForExistence(timeout:5))
        app.buttons["closeSiteScan"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
    }
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
    func testCameraPreviewFinishesInspectsAndReturnsToTheSameMap() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-site-capture"]; app.launch()
        XCTAssertTrue(app.buttons["closeSiteScan"].waitForExistence(timeout:10))
        let coverage = app.staticTexts["scanCoverage"]
        XCTAssertTrue(coverage.waitForExistence(timeout:5))
        let percent = try XCTUnwrap(Int(coverage.label.replacingOccurrences(of:"%",with:"")))
        XCTAssertTrue((0...100).contains(percent))
        let dots = app.descendants(matching:.any).matching(identifier:"skyCaptureDots").firstMatch
        XCTAssertTrue(dots.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label == %@","Демонстрация · камера не используется")).firstMatch.exists)
        XCTAssertFalse(app.otherElements["skyCamera"].exists,"This fixture must not start a hardware camera session.")
        XCTAssertTrue(app.buttons["scanTorch"].exists)
        XCTAssertFalse(app.buttons["scanTorch"].isEnabled,"Simulator preview must not claim a hardware flashlight.")
        XCTAssertTrue(app.staticTexts["Процент — охват камеры, не качество сигнала"].exists)
        let camera = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        camera.name = "scan-camera"; camera.lifetime = .keepAlways; add(camera)

        app.buttons["finishSiteScan"].tap()
        let dome = app.descendants(matching:.any).matching(identifier:"skyDome").firstMatch
        XCTAssertTrue(dome.waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["siteAssessment"].exists)
        let assessment = app.staticTexts["siteAssessment"].label
        XCTAssertFalse(coverage.exists)
        let result = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        result.name = "scan-result"; result.lifetime = .keepAlways; add(result)

        let inspect = app.buttons["inspectSiteScan"]
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<5 where !inspect.isHittable {
            scroll.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:0.80))
                .press(forDuration:0.05,thenDragTo:scroll.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:0.45)))
        }
        XCTAssertTrue(inspect.isHittable)
        inspect.tap()
        XCTAssertTrue(app.staticTexts["Осмотр места"].waitForExistence(timeout:5))
        XCTAssertTrue(dots.exists)
        XCTAssertFalse(coverage.exists,"Inspecting the existing map must not restart collection.")
        XCTAssertFalse(app.buttons["markSkyClear"].exists)
        XCTAssertFalse(app.otherElements["skyCamera"].exists)
        let inspecting = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        inspecting.name = "scan-inspect"; inspecting.lifetime = .keepAlways; add(inspecting)

        app.buttons["finishSiteScan"].tap()
        XCTAssertTrue(dome.waitForExistence(timeout:5))
        XCTAssertEqual(app.staticTexts["siteAssessment"].label,assessment,"Inspection must preserve the existing map assessment.")
        app.buttons["closeSiteScan"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["closeSiteScan"].exists)
    }
    func testRearPhoneInstructionsShowAndDismiss() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-radar-back-intro"]; app.launch()
        let title = app.staticTexts["introTitle"]
        XCTAssertTrue(title.waitForExistence(timeout:10))
        XCTAssertTrue(title.label.contains("Заднее стекло"))
        let rear = app.descendants(matching:.any).matching(NSPredicate(format:"label BEGINSWITH %@","Вид заднего стекла iPhone с тремя камерами.")).firstMatch
        XCTAssertTrue(rear.exists)
        let screenshot = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        screenshot.name = "rear-iphone-instructions"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Закрыть инструкцию"].tap()
        XCTAssertTrue(app.buttons["finishPointing"].waitForExistence(timeout:5))
        app.buttons["finishPointing"].tap()
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
