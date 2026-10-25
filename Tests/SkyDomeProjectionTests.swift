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

    func testSparsePointCloudReadsRealSurveyCellsWithoutPolarBands() {
        let mesh = SkyDomePoint.mesh
        XCTAssertEqual(mesh.count,1_536)
        XCTAssertEqual(SkySurvey.columns*SkySurvey.rows,3_600,"The capture grid is independent of the sparse display mesh.")
        // Equal increments of z divide the hemisphere into equal-area bands.
        // The former extra centre points must not form crowded zenith rings.
        for (first,last) in zip(mesh,mesh.dropFirst()) {
            XCTAssertEqual(last.vector.z-first.vector.z,1/Double(mesh.count),accuracy:1e-12)
        }
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

    func testObserverFacesRecordedWorldBearingWithPhoneInFront() {
        for bearing in [0.0,45,90,135,180,225,270,359] {
            let pose = SkyDomeObserverPose(startAzimuth:bearing)
            let expected = vector(bearing,0)
            XCTAssertEqual(pose.forward.x,expected.x,accuracy:1e-12)
            XCTAssertEqual(pose.forward.y,expected.y,accuracy:1e-12)
            XCTAssertEqual(pose.forward.dot(pose.right),0,accuracy:1e-12)
            let phone = pose.handsetPoint(0,0)
            XCTAssertGreaterThan(phone.dot(pose.forward),0,"The phone must remain ahead of the person.")
            XCTAssertEqual(phone.dot(pose.right),0,accuracy:1e-12,"The handset stays on the body's central plane.")
            XCTAssertGreaterThan(phone.z,0.4)
            let orientation = SkyDomeOrientation.resolve(startAzimuth:bearing,viewingDirection:nil)
            let projection = SkyDomeProjection(yaw:orientation.yaw,pitch:orientation.pitch)
            XCTAssertEqual(projection.projected(pose.forward).x,0,accuracy:1e-12)
            XCTAssertLessThan(projection.projected(pose.forward).depth,0,"The initial camera must see the person's back.")
        }
        XCTAssertEqual(SkyDomeObserverPose(startAzimuth:nil).forward,SkyDomeObserverPose(startAzimuth:.nan).forward)
    }

    func testBothArmsHaveEqualAnatomicalLengthsAndMirroredGrip() {
        for bearing in [0.0,90,135,225,359] {
            let pose = SkyDomeObserverPose(startAzimuth:bearing)
            let left = pose.arm(side:-1), right = pose.arm(side:1)
            for arm in [left,right] {
                let upper = arm.elbow.subtracting(arm.shoulder)
                let lower = arm.hand.subtracting(arm.elbow)
                XCTAssertEqual(sqrt(upper.dot(upper)),SkyDomeObserverPose.upperArmLength,accuracy:1e-12)
                XCTAssertEqual(sqrt(lower.dot(lower)),SkyDomeObserverPose.forearmLength,accuracy:1e-12)
            }
            for (a,b) in [(left.shoulder,right.shoulder),(left.elbow,right.elbow),(left.hand,right.hand)] {
                XCTAssertEqual(a.dot(pose.right),-b.dot(pose.right),accuracy:1e-12)
                XCTAssertEqual(a.dot(pose.forward),b.dot(pose.forward),accuracy:1e-12)
                XCTAssertEqual(a.z,b.z,accuracy:1e-12)
            }
            let gripCenter = left.hand.adding(right.hand).scaled(0.5)
            let phoneGrip = pose.handsetPoint(0,-0.05)
            XCTAssertEqual(gripCenter.x,phoneGrip.x,accuracy:1e-12)
            XCTAssertEqual(gripCenter.y,phoneGrip.y,accuracy:1e-12)
            XCTAssertEqual(gripCenter.z,phoneGrip.z,accuracy:1e-12)
        }
    }

    func testProCameraIslandHasThreeRigidLensesAcrossWorldRotation() {
        let lenses = SkyDomeObserverPose.cameraLenses
        XCTAssertEqual(lenses.count,3)
        let firstProduct = (lenses[1].x-lenses[0].x)*(lenses[2].y-lenses[0].y)
        let secondProduct = (lenses[1].y-lenses[0].y)*(lenses[2].x-lenses[0].x)
        let area = abs(firstProduct - secondProduct)
        XCTAssertGreaterThan(area,0.001,"The three lenses form a triangle, not a vertical strip.")
        for bearing in stride(from:0.0,to:360,by:15) {
            let pose = SkyDomeObserverPose(startAzimuth:bearing)
            let center = pose.handsetPoint(0,0)
            let points = lenses.map { pose.handsetPoint($0.x,$0.y,surfaceOffset:0.013) }
            for point in points {
                XCTAssertEqual(point.subtracting(center).dot(pose.handsetNormal),0.013,accuracy:1e-12)
            }
            for first in 0..<3 {
                for second in (first+1)..<3 {
                    let delta = points[first].subtracting(points[second])
                    let expected = hypot(lenses[first].x-lenses[second].x,lenses[first].y-lenses[second].y)
                    XCTAssertEqual(sqrt(delta.dot(delta)),expected,accuracy:1e-12)
                }
            }
            let back = SkyDomeProjection(yaw:180-bearing,pitch:32)
            let front = SkyDomeProjection(yaw:-bearing,pitch:32)
            XCTAssertGreaterThan(pose.handsetNormal.dot(back.towardCamera),0)
            XCTAssertLessThan(pose.handsetNormal.dot(front.towardCamera),0)
        }
    }

    func testFaceFeaturesBelongToFrontSurfaceOfHead() {
        for bearing in [0.0,90,225] {
            let pose = SkyDomeObserverPose(startAzimuth:bearing)
            let center = pose.point(height:0.60)
            let rearView = SkyDomeProjection(yaw:-bearing,pitch:32)
            XCTAssertLessThan(pose.forward.dot(rearView.towardCamera),0)
            for (side,height) in [(-0.017,0.012),(0.017,0.012),(0.0,-0.002),(0.0,-0.023)] {
                let offset = pose.facePoint(side:side,aboveCenter:height).subtracting(center)
                XCTAssertEqual(sqrt(offset.dot(offset)),0.056,accuracy:1e-12)
                XCTAssertGreaterThan(offset.dot(pose.forward),0)
                XCTAssertLessThan(offset.dot(rearView.towardCamera),0,"Facial features must not show through the back of the head.")
            }
        }
    }

    func testPhoneDecalsCannotSortBehindTheirBodyAtObliqueAngles() {
        let pose = SkyDomeObserverPose(startAzimuth:135)
        let surfaces = [pose.handsetPoint(0,0,surfaceOffset:0.004),
                        pose.handsetPoint(0.010,0.057,surfaceOffset:0.010)]
            + SkyDomeObserverPose.cameraLenses.map { pose.handsetPoint($0.x,$0.y,surfaceOffset:0.013) }
        var exposesOldSortingError = false
        for yaw in stride(from:0.0,to:360,by:10) {
            for pitch in [15.0,32,75] {
                let projection = SkyDomeProjection(yaw:yaw,pitch:pitch)
                guard pose.handsetNormal.dot(projection.towardCamera) > 0 else { continue }
                let anchor = projection.projected(pose.handsetPoint(0,0)).depth
                let depths = [anchor-1] + surfaces.map { projection.projected($0).depth } + [anchor+1]
                let group = SkyDomePaintGroup(range:1..<6,depth:anchor)
                let order = SkyDomePaintOrder.indices(depths:depths,groups:[group])
                XCTAssertEqual(order,[0,1,2,3,4,5,6],"Body, island and all three lenses retain their surface order.")
                if depths.indices.sorted(by:{ depths[$0] < depths[$1] }) != order { exposesOldSortingError = true }
            }
        }
        XCTAssertTrue(exposesOldSortingError,"Regression data must exercise the former mean-depth defect.")
    }

    func testObserverKeepsInitialHeadingWhenCameraShowsBackProfileOrFront() {
        let pose = SkyDomeObserverPose(startAzimuth:135)
        let forward = pose.forward
        var depths: [Double] = []
        for bearing in [135.0,225,315] {
            let orientation = SkyDomeOrientation.resolve(startAzimuth:135,viewingDirection:.init(azimuth:bearing,elevation:32))
            let projection = SkyDomeProjection(yaw:orientation.yaw,pitch:orientation.pitch)
            depths.append(projection.projected(pose.forward).depth)
            XCTAssertEqual(pose.forward,forward,"Inspection must rotate the camera, not the recorded observer.")
            let shoulders = [-0.108,0.108].map { pose.point(side:$0,height:0.425) }
            XCTAssertEqual(shoulders[0].z,shoulders[1].z,accuracy:1e-12)
            XCTAssertEqual(shoulders[1].dot(pose.right)-shoulders[0].dot(pose.right),0.216,accuracy:1e-12)
        }
        XCTAssertLessThan(depths[0],-0.8)
        XCTAssertEqual(depths[1],0,accuracy:1e-12)
        XCTAssertGreaterThan(depths[2],0.8)
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

    func testRecordedInitialBearingLooksFromBehindAndResetRestoresIt() {
        for start in [0.0,90,180,225,270,359] {
            let original = SkyDomeOrientation.resolve(startAzimuth:start,viewingDirection:nil)
            let projection = SkyDomeProjection(yaw:original.yaw,pitch:original.pitch,interior:true)
            XCTAssertLessThan(projection.projected(vector(start,0)).depth,0,"Camera is behind the recorded bearing.")
            XCTAssertTrue(projection.isVisible(vector(start,5)),"The cutaway exposes the sky ahead of the observer.")
            XCTAssertFalse(projection.isVisible(vector(start+180,5)))
            XCTAssertTrue(projection.isVisible(vector(start,89)),"A vertical cut must retain the zenith region.")
            XCTAssertEqual(projection.projected(vector(start,5)).x,0,accuracy:1e-12)
            let dragged = SkyDomeOrientation.resolve(startAzimuth:start,viewingDirection:nil,yawOffset:65,pitchOffset:18)
            XCTAssertNotEqual(dragged,original)
            XCTAssertEqual(SkyDomeOrientation.resolve(startAzimuth:start,viewingDirection:nil,yawOffset:0,pitchOffset:0),original)
        }
        let south = SkyDomeOrientation.resolve(startAzimuth:180,viewingDirection:nil)
        XCTAssertEqual(abs(south.yaw),180,accuracy:1e-12)
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
        XCTAssertEqual(live.yaw,140,accuracy:1e-10)
        XCTAssertEqual(live.pitch,40,accuracy:1e-10)
        let projection = SkyDomeProjection(yaw:live.yaw,pitch:live.pitch,interior:true)
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
        XCTAssertEqual(abs(SkyDomeOrientation.resolve(startAzimuth:.nan,viewingDirection:nil).yaw),180)
        XCTAssertEqual(SkyDomeOrientation.resolve(startAzimuth:135,viewingDirection:.init(azimuth:100,elevation:-30)).pitch,15)
        XCTAssertEqual(SkyDomeOrientation.resolve(startAzimuth:135,viewingDirection:.init(azimuth:100,elevation:90)).pitch,75)
    }

    func testInteriorTrackAndPointsUseTheSameVerticalCutaway() throws {
        let projection = SkyDomeProjection(yaw:-225,pitch:32,interior:true)
        for elevation in [0.0,20,60,89] {
            XCTAssertTrue(projection.isVisible(vector(225,elevation)))
            XCTAssertFalse(projection.isVisible(vector(45,elevation)))
        }
        XCTAssertNil(projection.visibleSegment(from:vector(25,30),to:vector(65,30)))
        let clipped = try XCTUnwrap(projection.visibleSegment(from:vector(100,35),to:vector(170,35)))
        XCTAssertEqual(projection.surfaceDepth(clipped.0),0,accuracy:1e-12)
        XCTAssertTrue(projection.isVisible(clipped.0))
        XCTAssertTrue(projection.isVisible(clipped.1))
        let patch = projection.visiblePolygon([vector(100,20),vector(170,20),vector(170,40),vector(100,40)])
        XCTAssertGreaterThanOrEqual(patch.count,3)
        XCTAssertTrue(patch.allSatisfy { projection.isVisible($0) })
        // The existing ENU compass places east to the right when looking north.
        let north = SkyDomeProjection(yaw:0,pitch:32,interior:true)
        XCTAssertGreaterThan(north.projected(vector(90,0)).x,0)
        XCTAssertLessThan(north.projected(vector(270,0)).x,0)
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
