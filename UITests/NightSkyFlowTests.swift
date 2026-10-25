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
    func testKeyboardAndSimulatedReply() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-screenshot-demo-chat"]; app.launch()
        let input = app.descendants(matching:.any).matching(NSPredicate(
            format:"identifier == %@ AND (elementType == %d OR elementType == %d)",
            "demoMessageInput", XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue
        )).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout:10)); input.tap(); input.typeText("Hello satellite")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.buttons["sendDemoMessage"].tap()
        XCTAssertTrue(app.staticTexts["Hello satellite"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Сообщение получено в тестовом диалоге. Это ответ симулятора."].waitForExistence(timeout:5))
        app.buttons["closeDemoChat"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
    }
}
