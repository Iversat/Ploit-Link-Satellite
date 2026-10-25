import XCTest
@testable import PloitSatellite

final class NightSkyTests: XCTestCase {
    func testSiderealReferenceAndLongitude() {
        let j2000 = Date(timeIntervalSince1970:946728000)
        XCTAssertEqual(NightSkyMath.siderealDegrees(at:j2000,longitude:0),280.46061837,accuracy:0.000001)
        XCTAssertEqual(NightSkyMath.siderealDegrees(at:j2000,longitude:90),10.46061837,accuracy:0.000001)
    }
    func testZenithPoleAndRisingSettingDirections() {
        XCTAssertEqual(NightSkyMath.vector(ra:120,dec:45,latitude:45,sidereal:120).up,1,accuracy:1e-9)
        XCTAssertEqual(NightSkyMath.angles(NightSkyMath.vector(ra:0,dec:90,latitude:48,sidereal:40)).elevation,48,accuracy:1e-8)
        let west = NightSkyMath.angles(NightSkyMath.vector(ra:0,dec:0,latitude:0,sidereal:90))
        let east = NightSkyMath.angles(NightSkyMath.vector(ra:180,dec:0,latitude:0,sidereal:90))
        XCTAssertEqual(west.azimuth,270,accuracy:1e-8); XCTAssertEqual(east.azimuth,90,accuracy:1e-8)
    }
    func testProjectionHandlesRollAndRejectsBelowHorizonAndBehind() {
        let basis = NightSkyMath.basis(azimuth:0,elevation:30)
        let projection = NightProjection(basis:basis,size:CGSize(width:400,height:800),focal:300)
        let center = projection.point(basis.z.negative)!
        XCTAssertEqual(center.x,200,accuracy:1e-8); XCTAssertEqual(center.y,400,accuracy:1e-8)
        XCTAssertNil(projection.point(basis.z))
        XCTAssertNil(projection.point(.init(north:0.8,west:0,up:-0.6)))
        XCTAssertEqual(basis.x.dot(basis.y),0,accuracy:1e-8)
        XCTAssertEqual(basis.x.cross(basis.y).dot(basis.z),1,accuracy:1e-8)
    }
    func testCatalogIncludesRealBrightStarsAndConstellations() throws {
        let catalog = try NightSkyCatalog.load()
        XCTAssertEqual(catalog.stars.count,5070)
        let sirius = try XCTUnwrap(catalog.stars.first { $0.name == "Сириус" })
        XCTAssertEqual(sirius.ra,101.287,accuracy:0.01); XCTAssertEqual(sirius.dec,-16.716,accuracy:0.01)
        XCTAssertEqual(Set(catalog.constellations.map(\.id)).count,catalog.constellations.count)
        XCTAssertEqual(catalog.constellations.first { $0.id == "UMa" }?.name,"Большая Медведица")
        XCTAssertNotNil(catalog.constellations.first { $0.id == "UMi" })
        XCTAssertGreaterThan(MilkyWayBand.samples.count,1000)
        XCTAssertTrue(catalog.stars.allSatisfy { $0.magnitude <= 6 && $0.ra.isFinite && (-90...90).contains($0.dec) })
    }
    func testWholeSkySnapshotsRemainFiniteAndPolygonsClipToViewport() throws {
        let catalog = try NightSkyCatalog.load()
        let snapshot = NightSkySnapshot.make(catalog:catalog,observer:.init(latitude:48.708,longitude:44.513,altitudeM:0),date:Date(timeIntervalSince1970:1792951200))
        XCTAssertEqual(snapshot.stars.count,catalog.stars.count)
        for az in stride(from:0.0,to:360,by:60) {
            let p = NightProjection(basis:NightSkyMath.basis(azimuth:az,elevation:45),size:CGSize(width:400,height:800),focal:280)
            for line in snapshot.lines {
                for point in p.clipped(line) {
                    XCTAssertTrue(point.x.isFinite && point.y.isFinite)
                    XCTAssertTrue(p.visible(point,margin:0.01))
                }
            }
        }
    }
    func testPrecessionIdentityAtJ2000AndFiniteAtPoles() {
        let value = NightSkyMath.precess(ra:120,dec:45,at:Date(timeIntervalSince1970:946728000))
        XCTAssertEqual(value.ra,120,accuracy:1e-8); XCTAssertEqual(value.dec,45,accuracy:1e-8)
        for dec in [-90.0,90] {
            let pole = NightSkyMath.precess(ra:0,dec:dec,at:Date(timeIntervalSince1970:1792951200))
            XCTAssertTrue(pole.ra.isFinite && pole.dec.isFinite)
        }
    }
    @MainActor func testDemoChatValidatesInputAndNeverClaimsRadioDelivery() async throws {
        let suite = "PLS-chat-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let chat = DemoChat(defaults:defaults)
        chat.send(" \n ",satellite:"МКС"); XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertFalse(DemoChat.valid(String(repeating:"a",count:281)))
        chat.send("Привет",satellite:"МКС")
        XCTAssertEqual(chat.messages.count,1)
        try await Task.sleep(nanoseconds:1_000_000_000)
        XCTAssertEqual(chat.messages.count,2)
        XCTAssertTrue(chat.messages.last!.text.contains("симулятора"))
        XCTAssertEqual(DemoChat(defaults:defaults).messages.count,2)
        chat.clear(); XCTAssertTrue(chat.messages.isEmpty)
    }
}
