import XCTest
@testable import PloitSatellite

final class ElementStoreTests: XCTestCase {
    private let oldLines=["1 25544U 98067A   26292.17690985  .00007130  00000+0  13772-3 0  9999",
                          "2 25544  51.6325  46.5189 0006763 282.0427  77.9804 15.48934931590976"]
    private let newLines=["1 25544U 98067A   26295.98338418  .00009682  00000-0  18356-3 0  9999",
                          "2 25544  51.6334  27.6879 0006864 297.6388  62.3903 15.49006294591569"]
    private func value(_ lines: [String]) throws -> Elements {
        try XCTUnwrap(Elements.parse(lines.joined(separator:"\n"),id:25544))
    }
    private func response(_ lines: [[String]], id: Int = 25544) throws -> Data {
        try JSONSerialization.data(withJSONObject:lines.map{["norad_cat_id":id,"tle1":$0[0],"tle2":$0[1]] as [String:Any]})
    }
    func testCacheUsesNewestValidEpochAcrossDiskAndBundle() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let old=try value(oldLines),new=try value(newLines),seed=folder.appendingPathComponent("seed.json"),disk=folder.appendingPathComponent("25544.json")
        let store=ElementStore(folder:folder,seedURL:seed)
        try JSONEncoder().encode([new]).write(to:seed); try JSONEncoder().encode(old).write(to:disk)
        let upgraded=await store.cached(id:25544)
        XCTAssertEqual(upgraded?.line1,new.line1)
        try JSONEncoder().encode([old]).write(to:seed); try JSONEncoder().encode(new).write(to:disk)
        let downloaded=await store.cached(id:25544)
        XCTAssertEqual(downloaded?.line1,new.line1)
        try Data("corrupted cache".utf8).write(to:disk)
        let fallback=await store.cached(id:25544)
        XCTAssertEqual(fallback?.line1,old.line1)
    }
    func testSatNOGSDecodesActualSchemaAndChoosesNewestValidEpoch() throws {
        let newest=try value(newLines),date=try XCTUnwrap(newest.epoch).addingTimeInterval(60)
        let result=try ElementStore.parseSatNOGS(response([newLines,oldLines]),id:25544,date:date)
        XCTAssertEqual(result.line1,newLines[0]); XCTAssertEqual(result.line2,newLines[1])
        XCTAssertEqual(result.fetchedAt,date)
    }
    func testSatNOGSRejectsEmptyWrongSatelliteCorruptAndStaleElements() throws {
        let newest=try value(newLines),date=try XCTUnwrap(newest.epoch).addingTimeInterval(60)
        XCTAssertThrowsError(try ElementStore.parseSatNOGS(Data("[]".utf8),id:25544,date:date))
        XCTAssertThrowsError(try ElementStore.parseSatNOGS(response([newLines],id:59112),id:25544,date:date))
        var damaged=newLines; damaged[0]=String(damaged[0].dropLast())+"0"
        XCTAssertThrowsError(try ElementStore.parseSatNOGS(response([damaged]),id:25544,date:date))
        XCTAssertThrowsError(try ElementStore.parseSatNOGS(response([newLines]),id:25544,date:date.addingTimeInterval(31*86400)))
    }
}
