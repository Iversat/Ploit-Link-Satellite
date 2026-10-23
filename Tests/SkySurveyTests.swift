import XCTest
@testable import PloitSatellite

final class SkySurveyTests: XCTestCase {
    func testDenseGridRoundTripsEveryCellAndSeparatesNearbyDirections() {
        XCTAssertEqual(SkySurvey.columns*SkySurvey.rows,1_296)
        for index in 0..<SkySurvey.columns*SkySurvey.rows {
            let direction = SkySurvey.direction(at:index)
            XCTAssertEqual(SkySurvey.index(azimuth:direction.azimuth,elevation:direction.elevation),index)
        }
        XCTAssertNotEqual(SkySurvey.index(azimuth:2.5,elevation:2.5),SkySurvey.index(azimuth:7.5,elevation:2.5))
        XCTAssertNotEqual(SkySurvey.index(azimuth:2.5,elevation:2.5),SkySurvey.index(azimuth:2.5,elevation:7.5))
        var west = SkySurvey()
        west.collect(Set(west.cells.indices.filter { SkySurvey.direction(at:$0).azimuth >= 180 }))
        XCTAssertEqual(west.coverageFraction,0.5,accuracy:1e-12)
    }
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
    func testCoverageIsAreaWeightedAndNeverMeansClear() {
        var horizon = SkySurvey(), zenith = SkySurvey(), full = SkySurvey()
        horizon.collect([0]); zenith.collect([(SkySurvey.rows-1)*SkySurvey.columns])
        XCTAssertGreaterThan(horizon.coverageFraction,zenith.coverageFraction)
        full.collect(Set(full.cells.indices))
        XCTAssertEqual(full.coverageFraction,1,"Complete coverage must format as exactly 100%, not 99% after floating-point summation.")
        XCTAssertEqual(full.coveredCellCount,SkySurvey.columns*SkySurvey.rows)
        XCTAssertTrue(full.cells.allSatisfy { $0 == .observed })
        let assessment = full.assessment(path:[SkySurvey.direction(at:0),SkySurvey.direction(at:200)])
        XCTAssertEqual(assessment.clear,0); XCTAssertEqual(assessment.unknown,2)
        let before = full.coverageFraction
        full.collect([-1,SkySurvey.columns*SkySurvey.rows,Int.max])
        XCTAssertEqual(full.coverageFraction,before)
    }
    func testCollectionPreservesExplicitClassificationsAndIsIdempotent() {
        var survey = SkySurvey()
        let blocked = SkySurvey.direction(at:30), clear = SkySurvey.direction(at:150)
        survey.mark(blocked,state:.blocked); survey.mark(clear,state:.clear)
        XCTAssertEqual(survey.coverageFraction,0,"Manual classification is separate from camera coverage.")
        XCTAssertEqual(survey.collect([30,150]),[30,150])
        XCTAssertTrue(survey.collect([30,150]).isEmpty)
        XCTAssertTrue(survey.collect([-1,SkySurvey.columns*SkySurvey.rows]).isEmpty)
        XCTAssertEqual(survey.coveredCellCount,2)
        XCTAssertEqual(survey.cells[30],.blocked); XCTAssertEqual(survey.cells[150],.clear)
    }
}
