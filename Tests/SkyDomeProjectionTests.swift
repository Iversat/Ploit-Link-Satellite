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

    func testPointCloudUsesEverySurveyCellWithoutChangingCoverage() {
        let mesh = SkyDomePoint.mesh
        XCTAssertEqual(mesh.count,3_072)
        XCTAssertEqual(Set(mesh.map(\.cell)).count,SkySurvey.columns*SkySurvey.rows)
        for point in mesh {
            XCTAssertEqual(point.vector.dot(point.vector),1,accuracy:1e-12)
            XCTAssertTrue((0...1).contains(point.vector.z))
            let azimuth = atan2(point.vector.x,point.vector.y)*180 / .pi
            let elevation = asin(point.vector.z)*180 / .pi
            XCTAssertEqual(SkySurvey.index(azimuth:azimuth,elevation:elevation),point.cell)
        }
        let empty = SkySurvey()
        XCTAssertTrue(mesh.allSatisfy { empty.cells[$0.cell] == .unknown })
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

    func testRecordedInitialBearingFacesVisibleSideAndResetRestoresIt() {
        for start in [0.0,90,180,270,359] {
            let original = SkyDomeOrientation.resolve(startAzimuth:start,viewingDirection:nil)
            let projection = SkyDomeProjection(yaw:original.yaw,pitch:original.pitch)
            XCTAssertTrue(projection.isVisible(vector(start,5)),"Recorded bearing must not be on the hidden half.")
            XCTAssertFalse(projection.isVisible(vector(start+180,5)))
            XCTAssertEqual(projection.projected(vector(start,5)).x,0,accuracy:1e-12)
            let dragged = SkyDomeOrientation.resolve(startAzimuth:start,viewingDirection:nil,yawOffset:65,pitchOffset:18)
            XCTAssertNotEqual(dragged,original)
            XCTAssertEqual(SkyDomeOrientation.resolve(startAzimuth:start,viewingDirection:nil,yawOffset:0,pitchOffset:0),original)
        }
        let south = SkyDomeOrientation.resolve(startAzimuth:180,viewingDirection:nil)
        XCTAssertEqual(south.yaw,0,accuracy:1e-12)
        XCTAssertEqual(south.pitch,32,accuracy:1e-12)
    }

    func testLiveInspectionUsesRearGlassEvenWhenPointingPreferenceIsTop() throws {
        let basis = AimMath.pose(azimuth:220,elevation:40,aiming:.back)
        let rear = try XCTUnwrap(SkyDomeOrientation.liveDirection(basis:basis,motionReady:true,northIsTrue:true,headingAccuracy:5))
        XCTAssertEqual(rear.azimuth,220,accuracy:1e-10)
        XCTAssertEqual(rear.elevation,40,accuracy:1e-10)
        let top = AimMath.direction(axis:.top,basis:basis)
        XCTAssertGreaterThan(AimMath.separation(az1:rear.azimuth,el1:rear.elevation,az2:top.az,el2:top.el),89)

        let live = SkyDomeOrientation.resolve(startAzimuth:135,viewingDirection:rear)
        XCTAssertEqual(live.yaw,-40,accuracy:1e-10)
        XCTAssertEqual(live.pitch,40,accuracy:1e-10)
        let projection = SkyDomeProjection(yaw:live.yaw,pitch:live.pitch)
        XCTAssertTrue(projection.isVisible(vector(220,10)))
        XCTAssertFalse(projection.isVisible(vector(40,10)))
    }

    func testUnreliableMotionCannotReorientSavedMap() {
        let basis = AimMath.pose(azimuth:220,elevation:40,aiming:.back)
        XCTAssertNil(SkyDomeOrientation.liveDirection(basis:nil,motionReady:true,northIsTrue:true,headingAccuracy:5))
        XCTAssertNil(SkyDomeOrientation.liveDirection(basis:basis,motionReady:false,northIsTrue:true,headingAccuracy:5))
        XCTAssertNil(SkyDomeOrientation.liveDirection(basis:basis,motionReady:true,northIsTrue:false,headingAccuracy:5))
        for accuracy in [-1.0,21,.nan,.infinity] {
            XCTAssertNil(SkyDomeOrientation.liveDirection(basis:basis,motionReady:true,northIsTrue:true,headingAccuracy:accuracy))
        }
        let original = SkyDomeOrientation.resolve(startAzimuth:135,viewingDirection:nil)
        XCTAssertEqual(SkyDomeOrientation.resolve(startAzimuth:135,viewingDirection:.init(azimuth:.nan,elevation:30)),original)
        XCTAssertEqual(SkyDomeOrientation.resolve(startAzimuth:135,viewingDirection:.init(azimuth:100,elevation:100)),original)
        XCTAssertEqual(SkyDomeOrientation.resolve(startAzimuth:.nan,viewingDirection:nil).yaw,0)
        XCTAssertEqual(SkyDomeOrientation.resolve(startAzimuth:135,viewingDirection:.init(azimuth:100,elevation:-30)).pitch,15)
        XCTAssertEqual(SkyDomeOrientation.resolve(startAzimuth:135,viewingDirection:.init(azimuth:100,elevation:90)).pitch,75)
    }

    func testCachedTrackRetainsDirectionsAndRejectsInvalidOrAntipodalSpans() throws {
        let first = SkyDirection(azimuth:170,elevation:20)
        let last = SkyDirection(azimuth:170,elevation:40)
        let segments = SkyDomeTrackSegment.make(path:[first,last])
        XCTAssertGreaterThan(segments.count,1)
        XCTAssertEqual(try XCTUnwrap(segments.first).from,vector(170,20))
        let end = try XCTUnwrap(segments.last).to
        XCTAssertEqual(end.x,vector(170,40).x,accuracy:1e-12)
        XCTAssertEqual(end.y,vector(170,40).y,accuracy:1e-12)
        XCTAssertEqual(end.z,vector(170,40).z,accuracy:1e-12)
        for segment in segments {
            XCTAssertEqual(segment.from.dot(segment.from),1,accuracy:1e-12)
            XCTAssertEqual(segment.to.dot(segment.to),1,accuracy:1e-12)
        }
        for (a,b) in zip(segments,segments.dropFirst()) { XCTAssertEqual(a.to,b.from) }
        XCTAssertTrue(SkyDomeTrackSegment.make(path:[.init(azimuth:0,elevation:0),.init(azimuth:180,elevation:0)]).isEmpty)
        XCTAssertTrue(SkyDomeTrackSegment.make(path:[.init(azimuth:.nan,elevation:0),last]).isEmpty)
        XCTAssertTrue(SkyDomeTrackSegment.make(path:[first]).isEmpty)
    }
}
