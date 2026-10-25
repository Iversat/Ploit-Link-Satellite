import XCTest
import simd
@testable import PloitSatellite

final class SkyScanGeometryTests: XCTestCase {
    func testCollectedDotsConvergeTowardCenterWithoutOvershooting() {
        let origin = CGPoint(x:0.8,y:0.25), center = CGPoint(x:0.5,y:0.5)
        XCTAssertEqual(SkyScanCollectionAnimation.point(from:origin,toward:center,progress:0),origin)
        XCTAssertEqual(SkyScanCollectionAnimation.point(from:origin,toward:center,progress:1),center)
        var lastDistance = Double.infinity
        for step in 0...20 {
            let point = SkyScanCollectionAnimation.point(from:origin,toward:center,progress:Double(step)/20)
            let distance = hypot(Double(point.x-center.x),Double(point.y-center.y))
            XCTAssertLessThanOrEqual(distance,lastDistance)
            lastDistance = distance
        }
        XCTAssertEqual(SkyScanCollectionAnimation.point(from:origin,toward:center,progress:.nan),origin)
        XCTAssertEqual(SkyScanCollectionAnimation.point(from:origin,toward:center,progress:2),center)
    }
    func testCollectionExcludesMeasuredControlsAndInvalidViewport() {
        let visible = CGRect(x:0,y:0.25,width:1,height:0.4)
        XCTAssertTrue(SkyScanCollectionArea.contains(CGPoint(x:0.5,y:0.5),visible:visible))
        XCTAssertFalse(SkyScanCollectionArea.contains(CGPoint(x:0.5,y:0.2),visible:visible),"A point hidden by the header must not collect.")
        XCTAssertFalse(SkyScanCollectionArea.contains(CGPoint(x:0.5,y:0.75),visible:visible),"A point hidden by the bottom controls must not collect.")
        XCTAssertFalse(SkyScanCollectionArea.contains(CGPoint(x:0.1,y:0.5),visible:visible),"Visible peripheral points still need central dwell.")
        for rect in [CGRect.zero,CGRect.null,CGRect.infinite,
                     CGRect(x:0.4,y:0.4,width:0.01,height:0.4),CGRect(x:0.4,y:0.4,width:-0.2,height:0.4)] {
            XCTAssertFalse(SkyScanCollectionArea.contains(CGPoint(x:0.5,y:0.5),visible:rect))
        }
    }
    func testNewCollectionAnimatesAndPulsesOnceButRevisitingStaysSilent() {
        var survey = SkySurvey(), animation = SkyScanCollectionAnimation(), feedback = SkyScanCollectionFeedback()
        let first = survey.collect([10,11])
        XCTAssertEqual(first,[10,11])
        animation.update(newIDs:first,at:1,enabled:true)
        XCTAssertEqual(animation.progress(for:10,at:1),0)
        XCTAssertTrue(feedback.shouldPulse(newCount:first.count,at:1,collecting:true,preview:false))
        let repeated = survey.collect([10,11])
        XCTAssertTrue(repeated.isEmpty)
        animation.update(newIDs:repeated,at:1.16,enabled:true)
        XCTAssertEqual(animation.progress(for:10,at:1.16) ?? -1,0.5,accuracy:0.00001)
        XCTAssertFalse(feedback.shouldPulse(newCount:repeated.count,at:1.16,collecting:true,preview:false))
        animation.update(newIDs:survey.collect([10,11]),at:2,enabled:true)
        XCTAssertNil(animation.progress(for:10,at:2))
        XCTAssertFalse(feedback.shouldPulse(newCount:survey.collect([10,11]).count,at:2,collecting:true,preview:false))
        animation.update(newIDs:[12],at:3,enabled:true)
        animation.update(newIDs:[],at:3.1,enabled:false)
        XCTAssertNil(animation.progress(for:12,at:3.1))
    }
    func testHiddenDirectionsNeedFreshVisibleDwellBeforeAffectingCoverage() {
        var survey = SkySurvey(), dwell = SkyScanDwell()
        let points = [10:CGPoint(x:0.5,y:0.75),11:CGPoint(x:0.5,y:0.5)]
        let masked = CGRect(x:0,y:0.25,width:1,height:0.4)
        func frame(_ time: Double,_ area: CGRect) -> Set<Int> {
            let candidates = Set(points.compactMap { id,point in
                !survey.collectedCells.contains(id) && SkyScanCollectionArea.contains(point,visible:area) ? id:nil
            })
            let progress = dwell.update(ids:candidates,at:time,enabled:true)
            return survey.collect(Set(progress.filter { $0.value >= 1 }.map(\.key)))
        }
        XCTAssertTrue(frame(0,masked).isEmpty)
        XCTAssertTrue(frame(0.2,masked).isEmpty)
        XCTAssertEqual(frame(0.4,masked),[11])
        XCTAssertEqual(survey.collectedCells,[11],"An occluded camera direction cannot increase coverage or trigger feedback.")
        XCTAssertTrue(frame(0.5,.zero).isEmpty)
        XCTAssertTrue(frame(0.6,SkyScanCollectionArea.central).isEmpty)
        XCTAssertTrue(frame(0.8,SkyScanCollectionArea.central).isEmpty,"The newly revealed point must not inherit hidden dwell time.")
        XCTAssertEqual(frame(1.01,SkyScanCollectionArea.central),[10])
        XCTAssertTrue(frame(1.2,SkyScanCollectionArea.central).isEmpty,"Revisiting covered directions cannot collect them again.")
    }
    func testPreviewUsesRealAngularProjectionWithoutFabricatedCollectionProgress() throws {
        var survey = SkySurvey()
        survey.collect(Set(survey.cells.indices.filter { SkySurvey.direction(at:$0).azimuth < 180 }))
        for size in [CGSize(width:390,height:844),CGSize(width:375,height:667)] {
            let targets = SkyScanPreviewGeometry.targets(survey:survey,size:size)
            XCTAssertGreaterThan(targets.count,30)
            XCTAssertTrue(targets.contains(where: \.collected))
            XCTAssertTrue(targets.contains(where: { !$0.collected }))
            XCTAssertTrue(targets.allSatisfy { $0.dwellFraction == 0 && $0.collectionProgress == nil })
            let projection = SkyScanPreviewGeometry.projection(size:size)
            // Compare the actual portrait FOV with the previous 5-degree grid.
            var previousVisibleCount = 0
            for elevation in stride(from:2.5,to:90.0,by:5.0) {
                for azimuth in stride(from:2.5,to:360.0,by:5.0) {
                    if projection.project(.init(azimuth:azimuth,elevation:elevation)) != nil { previousVisibleCount += 1 }
                }
            }
            XCTAssertGreaterThan(Double(targets.count),Double(previousVisibleCount)*2.5,
                                 "The denser grid must produce more visible targets in both tall and compact camera viewports.")
            for target in targets {
                let point = try XCTUnwrap(projection.project(SkySurvey.direction(at:target.id)))
                XCTAssertEqual(target.x,Double(point.x),accuracy:0.000001)
                XCTAssertEqual(target.y,Double(point.y),accuracy:0.000001)
            }
        }
    }
    private let intrinsics = simd_float3x3(SIMD3<Float>(500,0,0),SIMD3<Float>(0,500,0),SIMD3<Float>(500,500,1))
    private func projection(rotation: simd_float3x3 = matrix_identity_float3x3,
                            display: CGAffineTransform = .identity) -> SkyScanProjection {
        .init(cameraRotation:rotation,intrinsics:intrinsics,imageSize:CGSize(width:1000,height:1000),imageToViewport:display)
    }
    func testCachedDenseTargetsMatchSurveyDirections() throws {
        XCTAssertEqual(SkyScanProjection.targetDirections.count,SkySurvey.columns*SkySurvey.rows)
        let p = projection()
        for (index,world) in SkyScanProjection.targetDirections.enumerated() {
            let expected = try XCTUnwrap(SkyScanProjection.worldDirection(SkySurvey.direction(at:index)))
            XCTAssertLessThan(simd_distance(world,expected),0.000001)
            XCTAssertEqual(p.project(world:world),p.project(SkySurvey.direction(at:index)))
        }
    }
    func testCollectionFeedbackIsNewOnlyThrottledAndSilentInInspectionOrPreview() {
        var feedback = SkyScanCollectionFeedback()
        XCTAssertFalse(feedback.shouldPulse(newCount:0,at:0,collecting:true,preview:false))
        XCTAssertTrue(feedback.shouldPulse(newCount:20,at:0,collecting:true,preview:false))
        XCTAssertFalse(feedback.shouldPulse(newCount:1,at:0.24,collecting:true,preview:false))
        XCTAssertTrue(feedback.shouldPulse(newCount:1,at:0.25,collecting:true,preview:false))
        XCTAssertFalse(feedback.shouldPulse(newCount:1,at:1,collecting:false,preview:false))
        XCTAssertFalse(feedback.shouldPulse(newCount:1,at:1,collecting:true,preview:true))
        XCTAssertFalse(feedback.shouldPulse(newCount:0,at:1,collecting:true,preview:false))
        XCTAssertFalse(feedback.shouldPulse(newCount:1,at:.nan,collecting:true,preview:false))
        feedback.reset()
        XCTAssertTrue(feedback.shouldPulse(newCount:1,at:0,collecting:true,preview:false))
    }
    func testInitialHeadingRequiresValidScanPoseAndNeverFollowsLaterRotation() {
        let pose = SkyDirection(azimuth:-10,elevation:45)
        XCTAssertNil(SkyScanInitialHeading.capture(current:nil,direction:pose,collecting:true,trackingReady:false,headingReady:true))
        XCTAssertNil(SkyScanInitialHeading.capture(current:nil,direction:pose,collecting:true,trackingReady:true,headingReady:false))
        XCTAssertNil(SkyScanInitialHeading.capture(current:nil,direction:pose,collecting:false,trackingReady:true,headingReady:true))
        for elevation in [-90.0,90,.nan] {
            XCTAssertNil(SkyScanInitialHeading.capture(current:nil,direction:.init(azimuth:10,elevation:elevation),collecting:true,trackingReady:true,headingReady:true))
        }
        let initial = SkyScanInitialHeading.capture(current:nil,direction:pose,collecting:true,trackingReady:true,headingReady:true)
        XCTAssertEqual(initial,350)
        XCTAssertEqual(SkyScanInitialHeading.capture(current:nil,direction:.init(azimuth:225,elevation:-8),collecting:true,trackingReady:true,headingReady:true),225)
        XCTAssertEqual(SkyScanInitialHeading.capture(current:initial,direction:.init(azimuth:80,elevation:40),collecting:true,trackingReady:true,headingReady:true),350)
    }
    func testTrueNorthEastAndZenithUseARWorldAxes() throws {
        let north = try XCTUnwrap(SkyScanProjection.worldDirection(.init(azimuth:0,elevation:0)))
        let east = try XCTUnwrap(SkyScanProjection.worldDirection(.init(azimuth:90,elevation:0)))
        let zenith = try XCTUnwrap(SkyScanProjection.worldDirection(.init(azimuth:0,elevation:90)))
        XCTAssertLessThan(simd_distance(north,SIMD3<Float>(0,0,-1)),0.00001)
        XCTAssertLessThan(simd_distance(east,SIMD3<Float>(1,0,0)),0.00001)
        XCTAssertLessThan(simd_distance(zenith,SIMD3<Float>(0,1,0)),0.00001)
        XCTAssertNil(SkyScanProjection.worldDirection(.init(azimuth:.nan,elevation:30)))
        XCTAssertNil(SkyScanProjection.worldDirection(.init(azimuth:0,elevation:-1)))
    }
    func testProjectionRespectsFOVRearHemisphereAndDisplayCrop() throws {
        let p = projection()
        let north = try XCTUnwrap(p.project(.init(azimuth:0,elevation:0)))
        XCTAssertEqual(north.x,0.5,accuracy:0.00001); XCTAssertEqual(north.y,0.5,accuracy:0.00001)
        let eastward = try XCTUnwrap(p.project(.init(azimuth:30,elevation:0)))
        XCTAssertGreaterThan(eastward.x,north.x)
        let upward = try XCTUnwrap(p.project(.init(azimuth:0,elevation:30)))
        XCTAssertLessThan(upward.y,north.y)
        XCTAssertNil(p.project(.init(azimuth:60,elevation:0)))
        XCTAssertNil(p.project(.init(azimuth:180,elevation:20)))
        // A portrait display transform rotates the image, including its FOV crop.
        let rotated = projection(display:CGAffineTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0))
        let rotatedEast = try XCTUnwrap(rotated.project(.init(azimuth:30,elevation:0)))
        XCTAssertEqual(rotatedEast.x,1-eastward.y,accuracy:0.00001)
        XCTAssertEqual(rotatedEast.y,eastward.x,accuracy:0.00001)
        let cropped = projection(display:CGAffineTransform(a:2,b:0,c:0,d:1,tx:-0.5,ty:0))
        XCTAssertNil(cropped.project(.init(azimuth:30,elevation:0)))
    }
    func testWorldTargetMovesOppositeCameraYawWithoutChangingItsIdentity() throws {
        let facingEast = simd_float3x3(SIMD3<Float>(0,0,1),SIMD3<Float>(0,1,0),SIMD3<Float>(-1,0,0))
        let p = projection(rotation:facingEast)
        let east = try XCTUnwrap(p.project(.init(azimuth:90,elevation:0)))
        XCTAssertEqual(east.x,0.5,accuracy:0.00001)
        XCTAssertNil(p.project(.init(azimuth:0,elevation:0)))
        let towardEast = simd_float3x3(simd_quatf(angle:-Float.pi/6,axis:SIMD3<Float>(0,1,0)))
        let north = try XCTUnwrap(projection(rotation:towardEast).project(.init(azimuth:0,elevation:0)))
        XCTAssertLessThan(north.x,0.5)
    }
    func testCoverageRequiresContinuousCentralDwellAndResetsOnTrackingGap() {
        var dwell = SkyScanDwell()
        XCTAssertEqual(dwell.update(ids:[1],at:0,enabled:true)[1],0)
        XCTAssertEqual(dwell.update(ids:[1],at:0.2,enabled:true)[1] ?? -1,0.5,accuracy:0.00001)
        XCTAssertEqual(dwell.update(ids:[1],at:0.4,enabled:true)[1],1)
        XCTAssertTrue(dwell.update(ids:[],at:0.5,enabled:true).isEmpty)
        XCTAssertEqual(dwell.update(ids:[1],at:0.6,enabled:true)[1],0)
        XCTAssertEqual(dwell.update(ids:[1],at:1.2,enabled:true)[1],0,"A dropped tracking interval cannot collect unseen directions.")
        XCTAssertTrue(dwell.update(ids:[1],at:1.3,enabled:false).isEmpty)
        XCTAssertEqual(dwell.update(ids:[1],at:1.4,enabled:true)[1],0)
        XCTAssertEqual(dwell.update(ids:[1],at:1.0,enabled:true)[1],0)
    }
    @MainActor func testCaptureFixtureNeverStartsCameraAndInspectionPreservesMap() {
        let scan = SkyScanController()
        scan.preview(capture:true)
        XCTAssertFalse(scan.running)
        XCTAssertTrue(scan.collecting)
        XCTAssertEqual(scan.startAzimuth,135)
        XCTAssertFalse(scan.torchAvailable); XCTAssertFalse(scan.isTorchOn)
        XCTAssertTrue(scan.projectedTargets.contains(where: { !$0.collected }))
        XCTAssertEqual(scan.coverageFraction,0.5,accuracy:0.000001)
        XCTAssertFalse(scan.projectedTargets.isEmpty)
        let cells = scan.survey.cells, collected = scan.survey.collectedCells
        scan.checkLocation(.init(latitude:48.7,longitude:44.5,altitudeM:0))
        XCTAssertEqual(scan.survey.cells,cells,"A synthetic camera-free fixture has no measured site to invalidate.")
        scan.preview(capture:true,collecting:false)
        XCTAssertFalse(scan.running); XCTAssertFalse(scan.collecting)
        XCTAssertEqual(scan.survey.cells,cells); XCTAssertEqual(scan.survey.collectedCells,collected)
        scan.finish()
        XCTAssertTrue(scan.isSnapshot); XCTAssertFalse(scan.running)
        XCTAssertEqual(scan.startAzimuth,135)
        XCTAssertEqual(scan.survey.cells,cells); XCTAssertEqual(scan.survey.collectedCells,collected)
        scan.invalidate("Moved")
        XCTAssertEqual(scan.coverageFraction,0); XCTAssertFalse(scan.survey.hasRecordedData)
        XCTAssertNil(scan.startAzimuth)
    }
}
