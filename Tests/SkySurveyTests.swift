import XCTest
@testable import PloitSatellite

final class SkySurveyTests: XCTestCase {
    func testAbsentDepthNeverMeansOpenSky() {
        var survey = SkySurvey()
        let direction = SkyDirection(azimuth:30,elevation:45)
        for _ in 0..<10 { survey.observe(direction) }
        let result = survey.assessment(path:[direction])
        XCTAssertEqual(result.clear,0); XCTAssertEqual(result.unknown,1)
    }
    func testConfidentRepeatedNearbyDepthBlocksAndCannotBeClearedAccidentally() {
        var survey = SkySurvey()
        let direction = SkyDirection(azimuth:37.5,elevation:45)
        survey.observe(direction,obstacleDistance:2,highConfidence:true)
        XCTAssertEqual(survey.assessment(path:[direction]).blocked,0)
        survey.observe(direction,obstacleDistance:2,highConfidence:true)
        survey.mark(direction,state:.clear)
        XCTAssertEqual(survey.assessment(path:[direction]).blocked,1)
    }
    func testLowConfidenceFarAndInvalidDepthRemainUnknown() {
        var survey = SkySurvey()
        let direction = SkyDirection(azimuth:30,elevation:45)
        for _ in 0..<4 {
            survey.observe(direction,obstacleDistance:2,highConfidence:false)
            survey.observe(direction,obstacleDistance:20,highConfidence:true)
            survey.observe(direction,obstacleDistance:.nan,highConfidence:true)
        }
        XCTAssertEqual(survey.assessment(path:[direction]).unknown,1)
    }
    func testAnglesWrapAndBelowHorizonIsNotClassified() {
        XCTAssertEqual(SkySurvey.index(azimuth:0,elevation:90),SkySurvey.index(azimuth:360,elevation:90))
        XCTAssertEqual(SkySurvey.index(azimuth:-15,elevation:20),SkySurvey.index(azimuth:345,elevation:20))
        XCTAssertNil(SkySurvey.index(azimuth:.nan,elevation:20))
        XCTAssertNil(SkySurvey.index(azimuth:0,elevation:-1))
        var survey = SkySurvey()
        survey.mark(.init(azimuth:7.5,elevation:-1),state:.clear)
        XCTAssertFalse(survey.cells.contains(.clear))
    }
    func testManualClearAndUnknownRemainderCannotPromiseConnection() {
        var survey = SkySurvey()
        let clear = SkyDirection(azimuth:37.5,elevation:45), unseen = SkyDirection(azimuth:180,elevation:25)
        survey.mark(clear,state:.clear)
        let result = survey.assessment(path:[clear,unseen])
        XCTAssertEqual(result.clear,1); XCTAssertEqual(result.unknown,1)
        XCTAssertEqual(result.title,"Обзор ещё не проверен")
        XCTAssertEqual(survey.assessment(path:[]).title,"Нужен прогноз пролёта")
    }
}
