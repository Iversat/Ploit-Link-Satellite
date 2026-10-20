import XCTest

final class PointingFlowTests: XCTestCase {
    func testUnavailableEarthAndRadarShowSamePassAndNoConnection() {
        let app=XCUIApplication(); app.launchArguments=["--ui-screenshot-earth-unavailable"]; app.launch()
        let summary=app.descendants(matching:.any)["sessionSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout:15))
        expectation(for:NSPredicate(format:"label CONTAINS %@","До сеанса 10 мин"),evaluatedWith:summary)
        waitForExpectations(timeout:10)
        let before=summary.label
        XCTAssertTrue(app.staticTexts["pointingInstruction"].label.contains("Дождитесь"))
        app.buttons["showRadar"].tap()
        XCTAssertTrue(app.staticTexts["pointingStatus"].label.contains("ЗА ГОРИЗОНТОМ"))
        XCTAssertEqual(summary.label,before)
        XCTAssertFalse(app.buttons["confirmClearSky"].exists)
    }
    func testCorrectDirectionAloneDoesNotConfirmOpenSky() {
        let app=XCUIApplication(); app.launchArguments=["--ui-screenshot-earth-skycheck"]; app.launch()
        let button=app.buttons["confirmClearSky"]
        XCTAssertTrue(button.waitForExistence(timeout:15))
        XCTAssertFalse(app.staticTexts["pointingStatus"].label.contains("совпало"))
        button.tap()
        app.buttons["Я снаружи, направление не закрыто"].tap()
        let status=app.staticTexts["pointingStatus"]
        let aligned=expectation(for:NSPredicate(format:"label CONTAINS[c] %@","направление совпало"),evaluatedWith:status)
        XCTAssertEqual(XCTWaiter.wait(for:[aligned],timeout:5),.completed,"Status: \(status.label)\n\(app.debugDescription)")
        button.tap()
        let revoked=expectation(for:NSPredicate(format:"label CONTAINS[c] %@","проверьте обзор неба"),evaluatedWith:status)
        XCTAssertEqual(XCTWaiter.wait(for:[revoked],timeout:5),.completed,"Status: \(status.label)")
    }
    func testSettingsOpensRepeatedlyDuringLiveUpdatesFromButtonEdges() {
        let app=XCUIApplication(); app.launchArguments=["--ui-screenshot-home-settings-stress"]; app.launch()
        let open=app.buttons["openSettings"]
        XCTAssertTrue(open.waitForExistence(timeout:10))
        for i in 0..<4 {
            open.coordinate(withNormalizedOffset:CGVector(dx:i%2 == 0 ? 0.12:0.88,dy:0.5)).tap()
            XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout:2))
            app.buttons["closeSettings"].tap()
            XCTAssertTrue(open.waitForExistence(timeout:2)); XCTAssertTrue(open.isHittable)
        }
        app.buttons["openSatellites"].tap()
        XCTAssertTrue(app.navigationBars["Спутники"].waitForExistence(timeout:3))
        app.buttons["Готово"].tap()
        open.tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout:2))
    }
    override func setUpWithError() throws { continueAfterFailure = false }
    func testAxisSwitchChangesPhysicalDirection() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screenshot-radar-top-aligned"]
        app.launch()
        let status = app.staticTexts["pointingStatus"]
        XCTAssertTrue(status.waitForExistence(timeout:10))
        XCTAssertEqual(status.label,"НАПРАВЛЕНИЕ СОВПАЛО")
        let title=app.staticTexts["pointingTitle"]
        XCTAssertEqual(title.label,"Тренировка")
        XCTAssertEqual(title.frame.midX,app.windows.firstMatch.frame.midX,accuracy:1,"Title must be centered on screen despite unequal buttons.")
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
        XCTAssertEqual(app.otherElements["rearAimReticle"].value as? String,"Спутник в центре")
        app.buttons["showEarth"].tap()
        XCTAssertTrue(app.buttons["earthPasses"].waitForExistence(timeout:5))
        XCTAssertEqual(app.staticTexts["pointingTitle"].frame.midX,app.windows.firstMatch.frame.midX,accuracy:1)
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
        let scene=app.otherElements["orbitScene"]
        XCTAssertTrue(scene.waitForExistence(timeout:5))
        XCTAssertEqual(scene.frame.minY,app.windows.firstMatch.frame.minY,accuracy:1)
        XCTAssertEqual(scene.frame.maxY,app.windows.firstMatch.frame.maxY,accuracy:1,"The globe must render behind the floating panels, without an internal rectangular crop.")
        let before=scene.value as? String
        func component(_ key: String) -> String? {
            let parts=(scene.value as? String ?? "").split(separator:" ").map(String.init)
            guard let index=parts.firstIndex(of:key),index+1<parts.count else { return nil }
            return parts[index+1]
        }
        let oldPitch=component("pitch")
        XCTAssertGreaterThan(Double(component("insetTop") ?? "0") ?? 0,Double(app.buttons["closeOrbits"].frame.maxY))
        XCTAssertGreaterThan(Double(component("insetBottom") ?? "0") ?? 0,Double(app.windows.firstMatch.frame.height-timeline.frame.minY),"Floating panel measurements must reach the camera, including after SwiftUI reduces sibling preferences.")
        scene.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.32)).press(forDuration:0.05,thenDragTo:scene.coordinate(withNormalizedOffset:CGVector(dx:0.2,dy:0.32)))
        XCTAssertNotEqual(scene.value as? String,before)
        XCTAssertEqual(component("pitch"),oldPitch)
        let oldYaw=component("yaw")
        scene.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.42)).press(forDuration:0.05,thenDragTo:scene.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.22)))
        XCTAssertEqual(component("yaw"),oldYaw)
        XCTAssertTrue((scene.value as? String ?? "").contains("center 0 0"))
        scene.pinch(withScale:1.2,velocity:1)
        XCTAssertTrue(app.buttons["closeOrbits"].isHittable)
        let coordinates=app.descendants(matching:.any)["orbitCoordinates"]
        XCTAssertTrue(coordinates.waitForExistence(timeout:15))
        let oldCoordinates=coordinates.label
        timeline.adjust(toNormalizedSliderPosition:0.25)
        expectation(for:NSPredicate(format:"label != %@",oldCoordinates),evaluatedWith:coordinates)
        waitForExpectations(timeout:5)
        let mode=app.descendants(matching:.any)["orbitTimeMode"]
        XCTAssertTrue(mode.label.contains("ПРОГНОЗ"))
        XCTAssertTrue(app.buttons["jumpToSession"].waitForExistence(timeout:5))
        app.buttons["jumpToSession"].tap()
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
    func testCloseOrbitFromCatalogueAndReopen() {
        let app=XCUIApplication(); app.launchArguments=["--ui-screenshot-catalogue"]; app.launch()
        let open=app.buttons["Орбиты спутников"]
        XCTAssertTrue(open.waitForExistence(timeout:10)); open.tap()
        let close=app.buttons["closeOrbits"]
        XCTAssertTrue(close.waitForExistence(timeout:10)); close.tap()
        XCTAssertTrue(app.navigationBars["Спутники"].waitForExistence(timeout:5))
        open.tap(); XCTAssertTrue(close.waitForExistence(timeout:5)); close.tap()
        app.buttons["Готово"].tap()
        XCTAssertTrue(app.buttons["startPointing"].waitForExistence(timeout:5))
    }
    func testCloseWhilePlaying300AfterDragAndScrubRepeatedly() {
        let app=XCUIApplication(); app.launchArguments=["--ui-screenshot-orbits-playback"]; app.launch()
        for iteration in 0..<3 {
            let close=app.buttons["closeOrbits"]
            XCTAssertTrue(close.waitForExistence(timeout:15))
            let scene=app.otherElements["orbitScene"]
            XCTAssertTrue(app.descendants(matching:.any)["orbitCoordinates"].waitForExistence(timeout:15))
            if iteration>0 {
                app.buttons["orbitSpeed"].tap()
                app.buttons.matching(NSPredicate(format:"label == %@ AND identifier != %@","×300","orbitSpeed")).firstMatch.tap()
                if app.buttons["playOrbit"].label != "Пауза" { app.buttons["playOrbit"].tap() }
            }
            let date=app.staticTexts["orbitDate"],before=date.label
            let changes=expectation(for:NSPredicate(format:"label != %@",before),evaluatedWith:date)
            XCTAssertEqual(XCTWaiter.wait(for:[changes],timeout:4),.completed)
            scene.coordinate(withNormalizedOffset:CGVector(dx:0.75,dy:0.3)).press(forDuration:0.05,thenDragTo:scene.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.3)))
            app.sliders["orbitTimeline"].adjust(toNormalizedSliderPosition:0.18+Double(iteration)*0.06)
            app.buttons["playOrbit"].tap()
            close.tap()
            XCTAssertTrue(app.buttons["startPointing"].waitForExistence(timeout:3),"Close must work during playback and queued calculations")
            if iteration<2 { app.buttons["openOrbits"].tap() }
        }
    }
}
