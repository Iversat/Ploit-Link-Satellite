import XCTest
@testable import PloitSatellite

final class SkySceneFusionTests: XCTestCase {
    func testOutdoorSkyAndHouseKeepSeparateDirectionsAndAssessment() throws {
        let skyDirection = SkyDirection(azimuth:30,elevation:60)
        let houseDirection = SkyDirection(azimuth:150,elevation:30)
        let skyID = try XCTUnwrap(SkySurvey.index(azimuth:skyDirection.azimuth,elevation:skyDirection.elevation))
        let houseID = try XCTUnwrap(SkySurvey.index(azimuth:houseDirection.azimuth,elevation:houseDirection.elevation))
        let sky = SkySceneFusion.state(sample:.init(kind:.sky,confidence:0.99),distance:nil,
                                       depthReliable:false,environment:.outdoors)
        let house = SkySceneFusion.state(sample:.init(kind:.solid,confidence:0.99),distance:nil,
                                         depthReliable:false,environment:.outdoors)
        var survey = SkySurvey()
        for time in [10.0,10.65,11.3] {
            survey.applyAnalysis(index:skyID,state:sky,timestamp:time)
            survey.applyAnalysis(index:houseID,state:house,timestamp:time)
        }
        XCTAssertEqual(survey.cells[skyID],.clear)
        XCTAssertEqual(survey.cells[houseID],.blocked)
        let assessment = survey.assessment(path:[skyDirection,houseDirection])
        XCTAssertEqual(assessment.clear,1)
        XCTAssertEqual(assessment.blocked,1)
        XCTAssertEqual(assessment.unknown,0)
        XCTAssertEqual(survey.coveredCellCount,0,"Classification must not fabricate camera dwell coverage.")
    }

    func testIndoorWindowAndSkyThroughWindowAreOpeningsRatherThanRFAllClear() {
        for environment in [SkyScanEnvironment.automatic,.indoors,.outdoors] {
            XCTAssertEqual(SkySceneFusion.state(sample:.init(kind:.window,confidence:0.99),distance:nil,
                                                depthReliable:false,environment:environment),.opening)
        }
        for environment in [SkyScanEnvironment.automatic,.indoors] {
            XCTAssertEqual(SkySceneFusion.state(sample:.init(kind:.sky,confidence:0.99),distance:nil,
                                                depthReliable:false,environment:environment),.opening)
        }
        var survey = SkySurvey()
        let index = 500
        for time in [1.0,1.65] { survey.applyAnalysis(index:index,state:.opening,timestamp:time) }
        let assessment = survey.assessment(path:[SkySurvey.direction(at:index)])
        XCTAssertEqual(assessment.clear,0)
        XCTAssertEqual(assessment.opening,1)
        XCTAssertEqual(assessment.title,"Есть возможный просвет")
    }

    func testReliableNearbyDepthOverridesBothSkyAndWindowPredictions() {
        for distance in [0.2,2.0,6.0] {
            for sample in [SkySceneSample(kind:.sky,confidence:0.99),
                           SkySceneSample(kind:.window,confidence:0.99),
                           SkySceneSample(kind:.unknown,confidence:0)] {
                XCTAssertEqual(SkySceneFusion.state(sample:sample,distance:distance,
                                                    depthReliable:true,environment:.outdoors),.blocked)
            }
        }
        XCTAssertEqual(SkySceneFusion.state(sample:.init(kind:.sky,confidence:.nan),distance:2,
                                            depthReliable:true,environment:.outdoors),.blocked)
    }

    func testMissingInvalidFarOrUnreliableDepthCannotClassifyUnknownImageAsClear() {
        let distances: [Double?] = [nil,Double.nan,Double.infinity,-Double.infinity,-1,0,0.19,6.01,20]
        for distance in distances {
            XCTAssertEqual(SkySceneFusion.state(sample:.init(kind:.unknown,confidence:1),distance:distance,
                                                depthReliable:true,environment:.outdoors),.observed)
        }
        XCTAssertEqual(SkySceneFusion.state(sample:.init(kind:.unknown,confidence:1),distance:2,
                                            depthReliable:false,environment:.outdoors),.observed)
        // A confident outdoor sky prediction supplies image evidence independently of LiDAR.
        XCTAssertEqual(SkySceneFusion.state(sample:.init(kind:.sky,confidence:0.99),distance:nil,
                                            depthReliable:false,environment:.outdoors),.clear)
    }

    func testUncertainOrInvalidImageConfidenceRemainsObserved() {
        let samples = [SkySceneSample(kind:.sky,confidence:0.84),
                       SkySceneSample(kind:.solid,confidence:0.71),
                       SkySceneSample(kind:.window,confidence:0.59),
                       SkySceneSample(kind:.sky,confidence:.nan),
                       SkySceneSample(kind:.solid,confidence:.infinity),
                       SkySceneSample(kind:.window,confidence:-.infinity)]
        for sample in samples {
            XCTAssertEqual(SkySceneFusion.state(sample:sample,distance:nil,
                                                depthReliable:false,environment:.outdoors),.observed)
        }
    }

    func testClearRequiresThreeIndependentFramesWhileObstaclesRequireTwo() {
        var sky = SkyAnalysisVote(), obstacle = SkyAnalysisVote(), opening = SkyAnalysisVote()
        XCTAssertFalse(sky.accept(.clear,at:10))
        XCTAssertFalse(sky.accept(.clear,at:10.2),"Nearby samples cannot be counted as independent confirmations.")
        XCTAssertFalse(sky.accept(.clear,at:10.65))
        XCTAssertTrue(sky.accept(.clear,at:11.3))
        XCTAssertFalse(obstacle.accept(.blocked,at:10))
        XCTAssertTrue(obstacle.accept(.blocked,at:10.65))
        XCTAssertFalse(opening.accept(.opening,at:10))
        XCTAssertTrue(opening.accept(.opening,at:10.65))
    }

    func testChangedUnknownAndLongGapFramesBreakTemporalAgreement() {
        var vote = SkyAnalysisVote()
        XCTAssertFalse(vote.accept(.clear,at:1))
        XCTAssertFalse(vote.accept(.clear,at:1.65))
        XCTAssertFalse(vote.accept(.blocked,at:2.3))
        XCTAssertEqual(vote.count,1)
        XCTAssertFalse(vote.accept(.observed,at:2.95))
        XCTAssertEqual(vote.count,0)
        XCTAssertFalse(vote.accept(.clear,at:3.6))
        XCTAssertFalse(vote.accept(.clear,at:4.25))
        XCTAssertFalse(vote.accept(.clear,at:8),"A long interruption must require fresh confirmations.")
        XCTAssertEqual(vote.count,1)
    }

    func testStaleRepeatedAndInvalidTimestampsLeaveVoteUntouched() {
        var vote = SkyAnalysisVote()
        XCTAssertFalse(vote.accept(.clear,at:10))
        XCTAssertFalse(vote.accept(.clear,at:10.65))
        for time in [9.0,10.0,10.65,Double.nan,Double.infinity,-Double.infinity] {
            XCTAssertFalse(vote.accept(.blocked,at:time))
            XCTAssertFalse(vote.accept(.observed,at:time))
            XCTAssertEqual(vote.state,.clear)
            XCTAssertEqual(vote.count,2)
            XCTAssertEqual(vote.timestamp,10.65)
        }
        XCTAssertTrue(vote.accept(.clear,at:11.3))
    }

    func testLateFrameCannotRepaintAConfirmedClearSurveyCell() {
        var survey = SkySurvey()
        let index = 100
        for time in [10.0,10.65,11.3] { survey.applyAnalysis(index:index,state:.clear,timestamp:time) }
        for time in [1.0,1.65] { survey.applyAnalysis(index:index,state:.blocked,timestamp:time) }
        XCTAssertEqual(survey.cells[index],.clear,"Out-of-order inference cannot replace the current map.")
        for time in [12.0,12.65] { survey.applyAnalysis(index:index,state:.blocked,timestamp:time) }
        XCTAssertEqual(survey.cells[index],.blocked,"Fresh obstacle evidence still takes precedence.")
    }

    func testConfirmedObstacleCannotBeErasedByLaterSkyOrWindowVotes() {
        var survey = SkySurvey()
        let index = 700
        for time in [1.0,1.65] { survey.applyAnalysis(index:index,state:.blocked,timestamp:time) }
        for time in [2.3,2.95,3.6] { survey.applyAnalysis(index:index,state:.clear,timestamp:time) }
        for time in [4.25,4.9] { survey.applyAnalysis(index:index,state:.opening,timestamp:time) }
        XCTAssertEqual(survey.cells[index],.blocked)
    }

    func testRoomContextLatchesWhenCameraTurnsFromRoomTowardWindow() {
        var environment = SkySceneEnvironmentEstimate()
        environment.update(indoorEvidence:0.2)
        XCTAssertEqual(environment.inferred,.automatic)
        environment.update(indoorEvidence:0.2)
        XCTAssertEqual(environment.inferred,.indoors)
        for _ in 0..<10 { environment.update(indoorEvidence:0) }
        XCTAssertEqual(environment.inferred,.indoors,"Looking through a window cannot silently turn an indoor scan into outdoors.")
        XCTAssertEqual(environment.resolved(selection:.automatic),.indoors)
        XCTAssertEqual(environment.resolved(selection:.outdoors),.outdoors)
    }

    func testOutdoorEstimateNeedsAgreementAndFreshScanResetsRoomLatch() {
        var environment = SkySceneEnvironmentEstimate()
        environment.update(indoorEvidence:nil)
        environment.update(indoorEvidence:.nan)
        XCTAssertEqual(environment.inferred,.automatic)
        environment.update(indoorEvidence:0)
        environment.update(indoorEvidence:0)
        XCTAssertEqual(environment.inferred,.automatic)
        environment.update(indoorEvidence:0)
        XCTAssertEqual(environment.inferred,.outdoors)
        environment.update(indoorEvidence:0.2)
        environment.update(indoorEvidence:0.2)
        XCTAssertEqual(environment.inferred,.indoors)
        environment = SkySceneEnvironmentEstimate()
        XCTAssertEqual(environment.resolved(selection:.automatic),.automatic)
        XCTAssertEqual(environment.resolved(selection:.indoors),.indoors)
    }

    func testIndoorRestrictionDowngradesClearButPreservesObstaclesAndCoverage() {
        var survey = SkySurvey()
        let clearID = 100, blockedID = 200, observedID = 300
        survey.collect([clearID,blockedID,observedID])
        for time in [1.0,1.65,2.3] {
            survey.applyAnalysis(index:clearID,state:.clear,timestamp:time)
            survey.applyAnalysis(index:blockedID,state:.blocked,timestamp:time)
        }
        let coverage = survey.coverageFraction
        survey.restrictOpenSkyToApertures()
        XCTAssertEqual(survey.cells[clearID],.opening)
        XCTAssertEqual(survey.cells[blockedID],.blocked)
        XCTAssertEqual(survey.cells[observedID],.observed)
        XCTAssertEqual(survey.cells[400],.unknown)
        XCTAssertEqual(survey.coverageFraction,coverage)
        survey.applyAnalysis(index:clearID,state:.clear,timestamp:3)
        survey.applyAnalysis(index:clearID,state:.clear,timestamp:3.65)
        XCTAssertEqual(survey.cells[clearID],.opening,"Changing context must discard old clear confirmations.")
    }

    @MainActor func testSelectingIndoorContextRestrictsSnapshotWithoutWaitingForAnotherInference() {
        let scan = SkyScanController()
        scan.preview()
        XCTAssertTrue(scan.survey.cells.contains(.clear))
        let coverage = scan.survey.coverageFraction
        scan.environment = .indoors
        XCTAssertEqual(scan.sceneEnvironment,.indoors)
        XCTAssertFalse(scan.survey.cells.contains(.clear))
        XCTAssertTrue(scan.survey.cells.contains(.opening))
        XCTAssertTrue(scan.survey.cells.contains(.blocked))
        XCTAssertEqual(scan.survey.coverageFraction,coverage)
        scan.environment = .automatic
        XCTAssertFalse(scan.survey.cells.contains(.clear),"Returning to auto must not restore old all-clear classifications.")
    }
}
