import XCTest
@testable import PloitSatellite

final class SkyDomeProjectionTests: XCTestCase {
    private func vector(_ azimuth: Double,_ elevation: Double) -> SkyDomeVector {
        SkyDomeProjection.vector(.init(azimuth:azimuth,elevation:elevation))!
    }

    func testCardinalDirectionsMatchSurveyAndScreenAxes() {
        let projection = SkyDomeProjection()
        XCTAssertEqual(vector(0,0).y,1,accuracy:1e-12)
        XCTAssertEqual(vector(90,0).x,1,accuracy:1e-12)
        XCTAssertEqual(vector(0,90).z,1,accuracy:1e-12)
        XCTAssertGreaterThan(projection.projected(vector(90,0)).x,0)
        XCTAssertLessThan(projection.projected(vector(270,0)).x,0)
        XCTAssertGreaterThan(projection.projected(vector(0,0)).y,0)
        XCTAssertLessThan(projection.projected(vector(180,0)).y,0)
    }

    func testCameraBasisStaysOrthonormalAcrossRotationAndTilt() {
        for yaw in [-180.0,-90,0,45,179] {
            for pitch in [15.0,32,75] {
                let p = SkyDomeProjection(yaw:yaw,pitch:pitch)
                XCTAssertEqual(p.right.dot(p.up),0,accuracy:1e-12)
                XCTAssertEqual(p.right.dot(p.towardCamera),0,accuracy:1e-12)
                XCTAssertEqual(p.up.dot(p.towardCamera),0,accuracy:1e-12)
                XCTAssertEqual(p.towardCamera.dot(p.towardCamera),1,accuracy:1e-12)
            }
        }
    }

    func testFarSideAndBelowHorizonAreHidden() {
        let projection = SkyDomeProjection()
        XCTAssertFalse(projection.isVisible(vector(0,5)))
        XCTAssertTrue(projection.isVisible(vector(180,5)))
        XCTAssertTrue(projection.isVisible(vector(0,90)))
        XCTAssertFalse(projection.isVisible(vector(180,-1)))
        let rotated = SkyDomeProjection(yaw:180,pitch:32)
        XCTAssertTrue(rotated.isVisible(vector(0,5)))
        XCTAssertFalse(rotated.isVisible(vector(180,5)))
    }

    func testSurfacePatchClipsAtSameLimbAsTrack() throws {
        let projection = SkyDomeProjection()
        let hidden = [vector(352.5,0),vector(7.5,0),vector(7.5,10),vector(352.5,10)]
        XCTAssertTrue(projection.visiblePolygon(hidden).isEmpty)
        let crossing = [vector(352.5,50),vector(7.5,50),vector(7.5,70),vector(352.5,70)]
        let clipped = projection.visiblePolygon(crossing)
        XCTAssertGreaterThanOrEqual(clipped.count,3)
        XCTAssertTrue(clipped.allSatisfy { projection.isVisible($0) })
        let segment = try XCTUnwrap(projection.visibleSegment(from:vector(0,0),to:vector(0,90)))
        XCTAssertEqual(segment.0.dot(projection.towardCamera),0,accuracy:1e-12)
        XCTAssertEqual(asin(segment.0.z)*180 / .pi,58,accuracy:1e-10)
        XCTAssertEqual(projection.projected(segment.0).y,1,accuracy:1e-12)
        XCTAssertTrue(projection.isVisible(segment.1))
    }

    func testTrackRejectsHiddenSegmentsAndClipsHorizon() throws {
        let projection = SkyDomeProjection()
        XCTAssertNil(projection.visibleSegment(from:vector(0,0),to:vector(0,20)))
        XCTAssertNil(projection.visibleSegment(from:vector(180,-20),to:vector(180,-5)))
        let segment = try XCTUnwrap(projection.visibleSegment(from:vector(180,-10),to:vector(180,30)))
        XCTAssertEqual(segment.0.z,0,accuracy:1e-12)
        XCTAssertTrue(projection.isVisible(segment.0))
        XCTAssertTrue(projection.isVisible(segment.1))
        XCTAssertNil(SkyDomeProjection.vector(.init(azimuth:.nan,elevation:30)))
    }
}
