import XCTest
@testable import PloitSatellite

final class AimTests: XCTestCase {
    func testAngularWrapAcrossNorth() {
        XCTAssertEqual(AimMath.wrap(1 - 359),2,accuracy:0.000001)
        XCTAssertEqual(AimMath.wrap(359 - 1),-2,accuracy:0.000001)
    }
    func testSeparationAndZenith() {
        XCTAssertEqual(AimMath.separation(az1:359,el1:0,az2:1,el2:0),2,accuracy:0.000001)
        XCTAssertEqual(AimMath.separation(az1:0,el1:90,az2:180,el2:90),0,accuracy:0.000001)
        XCTAssertEqual(AimMath.separation(az1:0,el1:0,az2:180,el2:0),180,accuracy:0.000001)
    }
    func testNorthEastAndUpAxisConvention() {
        XCTAssertEqual(AimMath.direction(north:1,west:0,up:0).az,0,accuracy:0.000001)
        XCTAssertEqual(AimMath.direction(north:0,west:-1,up:0).az,90,accuracy:0.000001)
        XCTAssertEqual(AimMath.direction(north:0,west:1,up:0).az,270,accuracy:0.000001)
        XCTAssertEqual(AimMath.direction(north:1,west:0,up:1).el,45,accuracy:0.000001)
    }
    func testBundledTLEChecksumsAndEpoch() throws {
        let url=try XCTUnwrap(Bundle.main.url(forResource:"seed-tle",withExtension:"json"))
        let entries=try JSONDecoder().decode([Elements].self,from:Data(contentsOf:url))
        XCTAssertFalse(entries.isEmpty)
        for entry in entries { XCTAssertTrue(entry.valid(for:entry.norad));XCTAssertNotNil(entry.epoch) }
        var bad=try XCTUnwrap(entries.first);bad.line1=String(bad.line1.dropLast())+"X"
        XCTAssertFalse(bad.valid(for:bad.norad))
    }
    func testOrbitBridgeProducesFiniteLook() async throws {
        let url=try XCTUnwrap(Bundle.main.url(forResource:"seed-tle",withExtension:"json"))
        let entries=try JSONDecoder().decode([Elements].self,from:Data(contentsOf:url))
        let entry=try XCTUnwrap(entries.first(where:{$0.norad==25544}))
        let look=try await OrbitEngine().look(elements:entry,observer:.preview,date:try XCTUnwrap(entry.epoch))
        XCTAssertTrue((0...360).contains(look.azimuth));XCTAssertTrue((-90...90).contains(look.elevation))
        XCTAssertTrue((100...30000).contains(look.rangeKm));XCTAssertTrue(abs(look.rangeRate)<12)
    }
    func testDopplerSigns() {
        let receding=Look(azimuth:0,elevation:0,rangeKm:1000,rangeRate:5,latitude:0,longitude:0,altitudeKm:400)
        XCTAssertLessThan(receding.downlink(437.825),437.825)
        XCTAssertGreaterThan(receding.uplink(437.825),437.825)
    }
}
