import XCTest
@testable import PloitSatellite

final class SkyScanLifecycleTests: XCTestCase {
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
