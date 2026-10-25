import XCTest
@testable import PloitSatellite

final class SkyScanLifecycleTests: XCTestCase {
    @MainActor func testRoomGuidanceAndTargetsSurviveDownwardPoseAndUnreadyCompass() {
        let scan = SkyScanController(torch:TestSkyScanTorch())
        scan.previewRoom(headingAvailable:false)
        XCTAssertLessThan(scan.direction?.elevation ?? 0,0)
        XCTAssertFalse(scan.projectedTargets.isEmpty)
        XCTAssertEqual(scan.scanInstruction,"ОСМОТРИТЕ СТЕНЫ, ОКНА И ПОТОЛОК")
        XCTAssertFalse(scan.headingReady)
        let cells = scan.survey.cells
        scan.mark(.clear)
        XCTAssertEqual(scan.survey.cells,cells,"Unreferenced rays cannot alter the geographic map.")
    }
    @MainActor func testCollectionWaitsForMeasuredViewportAndResetsAcrossLifecycle() async {
        let scan = SkyScanController(torch:TestSkyScanTorch())
        let center = CGPoint(x:0.5,y:0.5)
        XCTAssertFalse(SkyScanCollectionArea.contains(center,visible:scan.collectionViewport))
        scan.collectionViewport = SkyScanCollectionArea.central
        XCTAssertTrue(SkyScanCollectionArea.contains(center,visible:scan.collectionViewport))
        scan.stop()
        XCTAssertEqual(scan.collectionViewport,.zero)
        XCTAssertFalse(SkyScanCollectionArea.contains(center,visible:scan.collectionViewport))
        scan.collectionViewport = SkyScanCollectionArea.central
        // Empty-map inspection exits before camera authorization on every device.
        // Even a rejected start must discard stale bounds from an earlier screen.
        await scan.start(observer:nil,collecting:false)
        XCTAssertFalse(scan.running)
        XCTAssertEqual(scan.collectionViewport,.zero)
        XCTAssertFalse(SkyScanCollectionArea.contains(center,visible:scan.collectionViewport))
    }

    @MainActor func testEveryStopPathRequestsTorchOffAndPreviewCannotEnableIt() {
        let torch = TestSkyScanTorch()
        let scan = SkyScanController(torch:torch)
        scan.preview(capture:true)
        scan.toggleTorch()
        XCTAssertFalse(scan.torchAvailable)
        scan.finish()
        scan.invalidate("Background")
        scan.sessionWasInterrupted(scan.session)
        scan.session(scan.session,didFailWithError:NSError(domain:"Test",code:1))
        XCTAssertEqual(torch.commands,[false,false,false,false,false])
        XCTAssertFalse(scan.isTorchOn); XCTAssertFalse(scan.torchAvailable)
    }

    @MainActor func testLateTorchReplyCannotOverrideNewerStopRequest() {
        let torch = TestSkyScanTorch(deferred:true)
        let scan = SkyScanController(torch:torch)
        scan.stop()
        scan.stop()
        torch.complete(at:0,active:true)
        XCTAssertFalse(scan.isTorchOn,"An obsolete ON/status reply must not resurrect the torch UI after Stop.")
        torch.complete(at:1,active:false)
        XCTAssertFalse(scan.isTorchOn); XCTAssertFalse(scan.torchAvailable)
        XCTAssertEqual(torch.commands,[false,false])
    }

    func testLocationChangeIgnoresSmallGPSNoiseButInvalidatesAnotherPoint() {
        let origin = Observer(latitude:48.708,longitude:44.513,altitudeM:100)
        XCTAssertFalse(SkyScanLocation.changed(from:origin,to:origin))
        XCTAssertFalse(SkyScanLocation.changed(from:origin,to:.init(latitude:48.70805,longitude:44.51305,altitudeM:105)))
        XCTAssertTrue(SkyScanLocation.changed(from:origin,to:.init(latitude:48.709,longitude:44.513,altitudeM:100)))
        XCTAssertTrue(SkyScanLocation.changed(from:origin,to:.init(latitude:48.708,longitude:44.513,altitudeM:130)))
        XCTAssertTrue(SkyScanLocation.changed(from:origin,to:nil))
        XCTAssertTrue(SkyScanLocation.changed(from:nil,to:origin))
        XCTAssertFalse(SkyScanLocation.changed(from:nil,to:nil))
    }

    func testLocationComparisonWrapsLongitudeAndRejectsInvalidCoordinates() {
        let origin = Observer(latitude:0,longitude:179.99999,altitudeM:0)
        XCTAssertFalse(SkyScanLocation.changed(from:origin,to:.init(latitude:0,longitude:-179.99999,altitudeM:0)))
        XCTAssertTrue(SkyScanLocation.changed(from:origin,to:.init(latitude:.nan,longitude:0,altitudeM:0)))
    }

    func testPathRefreshAdvancesOnlyDuringCurrentPass() {
        let pass = PassWindow(rise:9000,culmination:9090,set:9180,maxElevation:60,inProgress:false)
        func slice(_ seconds: Double) -> Int {
            SkyScanPathRefresh.timeSlice(for:pass,at:Date(timeIntervalSince1970:seconds))
        }
        XCTAssertEqual(slice(8999),0)
        XCTAssertEqual(slice(9000),slice(9029))
        XCTAssertNotEqual(slice(9029),slice(9030))
        XCTAssertEqual(slice(9180),0)
        XCTAssertEqual(SkyScanPathRefresh.timeSlice(for:nil,at:Date(timeIntervalSince1970:9050)),0)
    }

    @MainActor func testInvalidationRemovesPreviousPointSnapshot() {
        let controller = SkyScanController()
        controller.preview()
        controller.finish()
        XCTAssertTrue(controller.isSnapshot)
        XCTAssertTrue(controller.survey.cells.contains(.clear))
        controller.invalidate("Требуется новая проверка")
        XCTAssertFalse(controller.isSnapshot)
        XCTAssertFalse(controller.running)
        XCTAssertNil(controller.direction)
        XCTAssertTrue(controller.survey.cells.allSatisfy { $0 == .unknown })
        XCTAssertEqual(controller.message,"Требуется новая проверка")
    }
}


@MainActor private final class TestSkyScanTorch: SkyScanTorchControlling {
    var available = true
    var isOn = false
    var commands: [Bool] = []
    private var replies: [@MainActor (Bool,String?) -> Void] = []
    private let deferred: Bool
    init(deferred: Bool = false) { self.deferred = deferred }
    func setOn(_ enabled: Bool, completion: @escaping @MainActor (Bool,String?) -> Void) {
        commands.append(enabled)
        if deferred { replies.append(completion) }
        else { isOn = enabled; completion(enabled,nil) }
    }
    func complete(at index: Int, active: Bool) { isOn = active; replies[index](active,nil) }
}
