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

    func testConcurrentUpdatesShareOneRequestAndCheckTimeSurvivesRestart() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let clock=ElementTestClock(try XCTUnwrap(value(newLines).epoch).addingTimeInterval(60))
        let network=ElementNetworkStub(text:newLines.joined(separator:"\n"))
        let store=ElementStore(folder:folder,seedURL:folder.appendingPathComponent("no-seed.json"),now:{clock.value},loader:{try await network.load($0)})
        async let first=store.update(id:25544)
        async let second=store.update(id:25544)
        let values=try await (first,second)
        XCTAssertEqual(values.0,values.1)
        await assertCount(network,1)
        let repeated=try await store.update(id:25544)
        XCTAssertEqual(repeated,values.0)
        await assertCount(network,1)
        let restored=ElementStore(folder:folder,seedURL:folder.appendingPathComponent("no-seed.json"),now:{clock.value},loader:{try await network.load($0)})
        let due=await restored.needsUpdate(id:25544)
        XCTAssertFalse(due)
        _=try await restored.update(id:25544)
        await assertCount(network,1)
        clock.advance(7201)
        let expired=await restored.needsUpdate(id:25544)
        XCTAssertTrue(expired)
        _=try await restored.update(id:25544)
        await assertCount(network,2)
    }

    func testRefreshFailureKeepsOfflineOrbitAndBacksOff() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let known=try value(newLines)
        try JSONEncoder().encode(known).write(to:folder.appendingPathComponent("25544.json"))
        let clock=ElementTestClock(try XCTUnwrap(known.epoch).addingTimeInterval(60))
        let network=ElementNetworkStub(text:"",fails:true)
        let store=ElementStore(folder:folder,seedURL:folder.appendingPathComponent("no-seed.json"),now:{clock.value},loader:{try await network.load($0)})
        do { _=try await store.update(id:25544); XCTFail("Offline refresh must report failure") }
        catch { XCTAssertTrue(error is URLError) }
        let cached=await store.cached(id:25544)
        XCTAssertEqual(cached?.line1,known.line1)
        await assertCount(network,2)
        let coolingDown=await store.needsUpdate(id:25544)
        XCTAssertFalse(coolingDown)
        _=try await store.update(id:25544)
        await assertCount(network,2)
        clock.advance(301)
        let retry=await store.needsUpdate(id:25544)
        XCTAssertTrue(retry)
    }

    func testOlderRemoteElementsCannotReplaceNewerCache() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let known=try value(newLines),date=try XCTUnwrap(known.epoch).addingTimeInterval(60)
        try JSONEncoder().encode(known).write(to:folder.appendingPathComponent("25544.json"))
        let network=ElementNetworkStub(text:oldLines.joined(separator:"\n"))
        let store=ElementStore(folder:folder,seedURL:folder.appendingPathComponent("no-seed.json"),now:{date},loader:{try await network.load($0)})
        let updated=try await store.update(id:25544)
        XCTAssertEqual(updated.line1,known.line1)
        let cached=await store.cached(id:25544)
        XCTAssertEqual(cached?.line1,known.line1)
        let due=await store.needsUpdate(id:25544)
        XCTAssertFalse(due,"Checking an unchanged provider orbit must still start the two-hour cache interval")
    }

    func testBackgroundCancellationStopsInFlightDownloadWithoutReplacingCache() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let known=try value(newLines),date=try XCTUnwrap(known.epoch).addingTimeInterval(60)
        try JSONEncoder().encode(known).write(to:folder.appendingPathComponent("25544.json"))
        let network=ElementNetworkStub(text:oldLines.joined(separator:"\n"),delay:1_000_000_000)
        let store=ElementStore(folder:folder,seedURL:folder.appendingPathComponent("no-seed.json"),now:{date},loader:{try await network.load($0)})
        let task=Task { try await store.update(id:25544) }
        for _ in 0..<100 {
            if await network.count()>0 { break }
            try await Task.sleep(nanoseconds:1_000_000)
        }
        await store.cancelUpdates()
        do { _=try await task.value; XCTFail("Cancelled download must not complete") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cached=await store.cached(id:25544)
        XCTAssertEqual(cached?.line1,known.line1)
        await assertCount(network,1)
    }

    private func assertCount(_ network:ElementNetworkStub,_ expected:Int) async {
        let actual=await network.count()
        XCTAssertEqual(actual,expected)
    }
}

private actor ElementNetworkStub {
    private var calls=0
    private let text:String
    private let fails:Bool
    private let delay:UInt64
    init(text:String,fails:Bool=false,delay:UInt64=10_000_000) { self.text=text; self.fails=fails; self.delay=delay }
    func count()->Int { calls }
    func load(_ request:URLRequest) async throws -> (Data,URLResponse) {
        calls += 1
        try await Task.sleep(nanoseconds:delay)
        if fails { throw URLError(.notConnectedToInternet) }
        return (Data(text.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
}

private final class ElementTestClock: @unchecked Sendable {
    private let lock=NSLock()
    private var date:Date
    init(_ date:Date) { self.date=date }
    var value:Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds:TimeInterval) { lock.lock(); defer { lock.unlock() }; date=date.addingTimeInterval(seconds) }
}
