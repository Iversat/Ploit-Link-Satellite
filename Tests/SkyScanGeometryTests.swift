import XCTest
import simd
@testable import PloitSatellite

final class SkyScanGeometryTests: XCTestCase {
    private let intrinsics = simd_float3x3(SIMD3<Float>(500,0,0),SIMD3<Float>(0,500,0),SIMD3<Float>(500,500,1))
    private func projection(rotation: simd_float3x3 = matrix_identity_float3x3,
                            display: CGAffineTransform = .identity) -> SkyScanProjection {
        .init(cameraRotation:rotation,intrinsics:intrinsics,imageSize:CGSize(width:1000,height:1000),imageToViewport:display)
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
        XCTAssertEqual(scan.survey.cells,cells); XCTAssertEqual(scan.survey.collectedCells,collected)
        scan.invalidate("Moved")
        XCTAssertEqual(scan.coverageFraction,0); XCTAssertFalse(scan.survey.hasRecordedData)
    }
}
