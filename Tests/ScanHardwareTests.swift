import XCTest
@testable import PloitSatellite

final class ScanHardwareTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970:1000)

    func testHeadingAcquisitionRequiresRecentTrueNorth() {
        var reference = ScanHeadingReference()
        reference.receive(accuracy:5,trueHeading:-1,timestamp:origin,now:origin)
        XCTAssertFalse(reference.isReady(at:origin))
        reference.receive(accuracy:5,trueHeading:42,timestamp:origin.addingTimeInterval(-10),now:origin)
        XCTAssertFalse(reference.isReady(at:origin))
        reference.receive(accuracy:25,trueHeading:42,timestamp:origin,now:origin)
        XCTAssertFalse(reference.isReady(at:origin))
        reference.receive(accuracy:5,trueHeading:42,timestamp:origin,now:origin)
        XCTAssertTrue(reference.isReady(at:origin))
    }

    func testHeadingDoesNotDropAtOldTwentyDegreeThreshold() {
        var reference = ScanHeadingReference()
        reference.receive(accuracy:10,trueHeading:42,timestamp:origin,now:origin)
        let later = origin.addingTimeInterval(4)
        reference.receive(accuracy:24,trueHeading:42,timestamp:later,now:later)
        XCTAssertTrue(reference.isReady(at:origin.addingTimeInterval(8)))
    }

    func testTemporaryHeadingLossHasBoundedGraceAndRequiresReacquisition() {
        var reference = ScanHeadingReference()
        reference.receive(accuracy:10,trueHeading:42,timestamp:origin,now:origin)
        let later = origin.addingTimeInterval(2)
        reference.receive(accuracy:-1,trueHeading:-1,timestamp:later,now:later)
        XCTAssertTrue(reference.isReady(at:later))
        let expired = origin.addingTimeInterval(6)
        XCTAssertFalse(reference.isReady(at:expired))
        reference.receive(accuracy:25,trueHeading:42,timestamp:expired,now:expired)
        XCTAssertFalse(reference.isReady(at:expired))
        reference.receive(accuracy:10,trueHeading:42,timestamp:expired,now:expired)
        XCTAssertTrue(reference.isReady(at:expired))
        reference.reset()
        XCTAssertFalse(reference.isReady(at:expired))
    }

    func testHeadingCannotAcceptNonfiniteOrFutureSamples() {
        var reference = ScanHeadingReference()
        reference.receive(accuracy:.nan,trueHeading:42,timestamp:origin,now:origin)
        reference.receive(accuracy:1,trueHeading:.infinity,timestamp:origin,now:origin)
        reference.receive(accuracy:1,trueHeading:42,timestamp:origin.addingTimeInterval(30),now:origin)
        XCTAssertFalse(reference.isReady(at:origin))
    }

    @MainActor func testTorchResolvesCameraAfterSessionStartupAndRetriesAvailability() async {
        let camera = MockScanTorchDevice("active")
        camera.available = false
        var cameras: [ScanTorchDevice] = []
        let torch = SystemSkyScanTorch(resolve:{ cameras })
        XCTAssertFalse(torch.available)
        cameras = [camera]
        XCTAssertTrue(torch.available,"Runtime availability must not disable the hardware button.")
        let unavailable = await command(torch,true)
        XCTAssertFalse(unavailable.0); XCTAssertNotNil(unavailable.1)
        camera.available = true
        let on = await command(torch,true)
        XCTAssertTrue(on.0); XCTAssertNil(on.1)
        let off = await command(torch,false)
        XCTAssertFalse(off.0); XCTAssertNil(off.1)
        XCTAssertEqual(camera.commands,[true,false])
    }

    @MainActor func testTorchFallsBackAndTurnsOffPreviousCaptureDevice() async {
        let rejected = MockScanTorchDevice("ar")
        rejected.failsOn = true
        let wide = MockScanTorchDevice("wide")
        var cameras: [ScanTorchDevice] = [rejected,wide]
        let torch = SystemSkyScanTorch(resolve:{ cameras })
        let on = await command(torch,true)
        XCTAssertTrue(on.0); XCTAssertTrue(wide.active)
        cameras = [] // ARSession paused; device lookup no longer returns it.
        let off = await command(torch,false)
        XCTAssertFalse(off.0); XCTAssertFalse(wide.active)
        XCTAssertEqual(wide.commands,[true,false])
    }

    @MainActor func testQueuedOffAlwaysFollowsQueuedOn() async {
        let camera = MockScanTorchDevice("wide")
        let torch = SystemSkyScanTorch(resolve:{ [camera] })
        let finished = expectation(description:"Off completed")
        torch.setOn(true) { _,_ in }
        torch.setOn(false) { active,error in
            XCTAssertFalse(active); XCTAssertNil(error); finished.fulfill()
        }
        await fulfillment(of:[finished],timeout:3)
        XCTAssertEqual(camera.commands,[true,false])
        XCTAssertFalse(torch.isOn)
    }

    @MainActor func testSilentInactiveTorchTriesAnotherCameraAndReportsFailure() async {
        let dark = MockScanTorchDevice("dark")
        dark.silentFailure = true
        let working = MockScanTorchDevice("working")
        let torch = SystemSkyScanTorch(resolve:{ [dark,working] })
        let result = await command(torch,true)
        XCTAssertTrue(result.0); XCTAssertNil(result.1)
        XCTAssertEqual(dark.commands,[true,false])
        _ = await command(torch,false)
        let failed = SystemSkyScanTorch(resolve:{ [dark] })
        let error = await command(failed,true)
        XCTAssertFalse(error.0); XCTAssertNotNil(error.1)
    }

    @MainActor private func command(_ torch: SystemSkyScanTorch,_ enabled: Bool) async -> (Bool,String?) {
        await withCheckedContinuation { continuation in
            torch.setOn(enabled) { active,error in continuation.resume(returning:(active,error)) }
        }
    }
}

private final class MockScanTorchDevice: ScanTorchDevice {
    let id: String
    var supported = true
    var available = true
    var active = false
    var failsOn = false
    var silentFailure = false
    var commands: [Bool] = []
    init(_ id: String) { self.id = id }
    func setEnabled(_ enabled: Bool) throws {
        if enabled && failsOn { throw NSError(domain:"TorchTest",code:1) }
        commands.append(enabled); active = enabled && !silentFailure
    }
}
