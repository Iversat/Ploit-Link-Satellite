import XCTest

final class NightSkyFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testExploreFindConstellationAndClose() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-night-sky"]; app.launch()
        let canvas = app.descendants(matching:.any).matching(identifier:"nightSkyCanvas").firstMatch
        XCTAssertTrue(app.buttons["findSkyObject"].waitForExistence(timeout:15))
        let old = canvas.value as? String
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.45)).press(forDuration:0.05,thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.7,dy:0.5)))
        XCTAssertNotEqual(canvas.value as? String,old)
        app.buttons["findSkyObject"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:5)); search.tap(); search.typeText("UMa")
        let target = app.buttons.matching(NSPredicate(format:"label CONTAINS[cd] %@","Большая Медведица")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout:5)); target.tap()
        XCTAssertTrue(app.staticTexts["Большая Медведица"].waitForExistence(timeout:5))
        XCTAssertTrue(app.sliders["nightTimeSlider"].exists)
        app.sliders["nightTimeSlider"].adjust(toNormalizedSliderPosition:0.8)
        app.buttons["closeNightSky"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
    }
    func testGyroscopeAimsWithoutOpeningCameraAndReturnsToFreeView() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-night-sky-gyro"]; app.launch()
        XCTAssertTrue(app.staticTexts["gyroSkyHint"].waitForExistence(timeout:15))
        XCTAssertTrue(app.staticTexts["Объект в центре"].exists)
        let canvas = app.descendants(matching:.any).matching(identifier:"nightSkyCanvas").firstMatch
        XCTAssertTrue((canvas.value as? String ?? "").contains("camera off"))
        XCTAssertFalse(app.sliders["nightTimeSlider"].exists)
        app.segmentedControls["nightSkyMode"].buttons["Обзор"].tap()
        XCTAssertTrue(app.sliders["nightTimeSlider"].waitForExistence(timeout:5))
        app.segmentedControls["nightSkyMode"].buttons["Гироскоп"].tap()
        XCTAssertTrue(app.staticTexts["gyroSkyHint"].waitForExistence(timeout:5))
        XCTAssertTrue((canvas.value as? String ?? "").contains("camera off"))
        app.buttons["closeNightSky"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
    }
    func testKeyboardAndSimulatedReply() { checkConversation(suffix:"") }
    func testRearAimRemainsVisibleWhileTypingAndChangingAxis() { checkConversation(suffix:"-back") }
    private func checkConversation(suffix: String) {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-demo-chat"+suffix]; app.launch()
        let input = app.descendants(matching:.any).matching(NSPredicate(
            format:"identifier == %@ AND (elementType == %d OR elementType == %d)",
            "demoMessageInput", XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue
        )).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout:10)); input.tap(); input.typeText("Hello satellite"+suffix)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let aim = app.descendants(matching:.any).matching(identifier:"conversationAim").firstMatch
        XCTAssertTrue(aim.exists)
        XCTAssertLessThan(aim.frame.maxY,app.keyboards.firstMatch.frame.minY)
        let axis = app.segmentedControls["aimAxis"]
        let original = suffix.isEmpty ? "Верхняя грань":"Заднее стекло"
        let other = suffix.isEmpty ? "Заднее стекло":"Верхняя грань"
        axis.buttons[other].tap()
        XCTAssertFalse(app.buttons["sendDemoMessage"].isEnabled)
        XCTAssertTrue((input.value as? String ?? "").contains("Hello satellite"))
        axis.buttons[original].tap()
        XCTAssertTrue(app.buttons["sendDemoMessage"].isEnabled)
        app.buttons["sendDemoMessage"].tap()
        XCTAssertTrue(app.staticTexts["Hello satellite"+suffix].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label == %@","Сообщение получено в тестовом диалоге. Это ответ симулятора.")).firstMatch.waitForExistence(timeout:5))
        let image = XCTAttachment(screenshot:app.screenshot()); image.name = "pointing-keyboard"+suffix; image.lifetime = .keepAlways; add(image)
        app.buttons["closeDemoChat"].tap()
        XCTAssertTrue(app.buttons["openPointingMessages"].waitForExistence(timeout:5))
        app.buttons["finishPointing"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
    }
    func testExploreBelowHorizonAndCenterSelectedObject() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-night-sky-below"]; app.launch()
        XCTAssertTrue(app.staticTexts["belowSkyHorizon"].waitForExistence(timeout:15))
        app.buttons["centerSkyTarget"].tap()
        XCTAssertTrue(app.staticTexts["Объект в центре"].waitForExistence(timeout:5))
        app.buttons["closeNightSky"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
    }
}
