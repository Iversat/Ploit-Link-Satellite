import XCTest
@testable import PloitSatellite

final class SessionRecommendationTests: XCTestCase {
    private struct Fixture {
        var satellites: [Satellite]
        var elements: [Int:Elements]
        var contexts: [Int:SessionPredictionContext]
        var windows: [Int:[PassWindow]] = [:]
        var date: Date
        func result(observer: Observer? = .preview, mask: Double = 20, preferred: Int? = nil) -> SessionRecommendation? {
            SessionRecommendation.best(satellites:satellites,windows:windows,contexts:contexts,elements:elements,
                                       observer:observer,minimumElevation:mask,date:date,preferredID:preferred)
        }
        mutating func window(_ index: Int, rise: Double, set: Double, elevation: Double = 60) {
            let start=date.addingTimeInterval(rise).timeIntervalSince1970,end=date.addingTimeInterval(set).timeIntervalSince1970
            windows[satellites[index].id]=[PassWindow(rise:start,culmination:(start+end)/2,set:end,maxElevation:elevation,inProgress:rise<0)]
        }
    }
    private func fixture() throws -> Fixture {
        let url=try XCTUnwrap(Bundle.main.url(forResource:"seed-tle",withExtension:"json"))
        let values=try JSONDecoder().decode([Elements].self,from:Data(contentsOf:url))
        XCTAssertGreaterThanOrEqual(values.count,3)
        let date=try XCTUnwrap(values.first?.epoch)
        let satellites=values.prefix(3).enumerated().map { index,tle in
            Satellite(id:tle.norad,name:"SAT-\(index)",subtitle:"",kind:"",modes:[RadioMode(id:"relay",name:"Relay",uplinkMHz:145.825,downlinkMHz:145.825,detail:"",canRelay:true)],status:"",source:"",checked:"")
        }
        return Fixture(satellites:satellites,elements:Dictionary(uniqueKeysWithValues:values.map{($0.norad,$0)}),
                       contexts:Dictionary(uniqueKeysWithValues:values.map{($0.norad,SessionPredictionContext(observer:.preview,minimumElevation:20,elements:$0))}),date:date)
    }
    func testCurrentVisibilityWinsOverUpcomingAndDoesNotClaimConnection() throws {
        var f=try fixture(); f.window(0,rise:60,set:360); f.window(1,rise:-60,set:240)
        let result=try XCTUnwrap(f.result())
        XCTAssertEqual(result.satellite.id,f.satellites[1].id)
        XCTAssertTrue(result.isCurrent); XCTAssertFalse(result.isWithinHour)
        XCTAssertTrue(result.headline.hasPrefix("Окно видимости сейчас"))
    }
    func testWithinHourBoundaryAndLaterFallback() throws {
        var f=try fixture(); f.window(0,rise:3600,set:3900)
        XCTAssertTrue(try XCTUnwrap(f.result()).isWithinHour)
        XCTAssertTrue(try XCTUnwrap(f.result()).headline.hasPrefix("В течение часа"))
        f.window(0,rise:3601,set:3901)
        XCTAssertFalse(try XCTUnwrap(f.result()).isWithinHour)
        XCTAssertTrue(try XCTUnwrap(f.result()).headline.hasPrefix("Ближайший пролёт"))
    }
    func testTelemetryAndMissingUplinkAreNotAutomaticCandidates() throws {
        var f=try fixture(); f.window(0,rise:-60,set:240); f.window(1,rise:60,set:360); f.window(2,rise:600,set:900)
        f.satellites[0].modes[0].canRelay=false
        f.satellites[1].modes[0].uplinkMHz=nil
        XCTAssertEqual(f.result()?.satellite.id,f.satellites[2].id)
        f.satellites[2].modes=[]
        XCTAssertNil(f.result())
    }
    func testAutoRetainsEligibleFMButReplacesTelemetryOrInvalidModes() throws {
        var satellite=try fixture().satellites[0]
        satellite.modes=[
            RadioMode(id:"aprs",name:"APRS",uplinkMHz:437.825,downlinkMHz:437.825,detail:"",canRelay:true),
            RadioMode(id:"fm",name:"FM",uplinkMHz:145.99,downlinkMHz:437.8,detail:"",canRelay:true),
            RadioMode(id:"telemetry",name:"Telemetry",uplinkMHz:nil,downlinkMHz:437.025,detail:"",canRelay:false)
        ]
        XCTAssertEqual(SessionRecommendation.preferredRelayMode(in:satellite,preferredID:"fm")?.id,"fm")
        XCTAssertEqual(SessionRecommendation.preferredRelayMode(in:satellite,preferredID:"telemetry")?.id,"aprs")
        satellite.modes[1].uplinkMHz = .nan
        XCTAssertEqual(SessionRecommendation.preferredRelayMode(in:satellite,preferredID:"fm")?.id,"aprs")
        XCTAssertEqual(SessionRecommendation.preferredRelayMode(in:satellite,preferredID:"missing")?.id,"aprs")
    }
    func testEqualStartKeepsSelectionThenUsesElevationAndStableID() throws {
        var f=try fixture(); f.window(0,rise:60,set:360,elevation:40); f.window(1,rise:60,set:360,elevation:70)
        XCTAssertEqual(f.result(preferred:f.satellites[0].id)?.satellite.id,f.satellites[0].id)
        XCTAssertEqual(f.result()?.satellite.id,f.satellites[1].id)
        f.window(0,rise:60,set:360,elevation:70)
        XCTAssertEqual(f.result()?.satellite.id,min(f.satellites[0].id,f.satellites[1].id))
    }
    func testExpiredLowAndMalformedWindowsAreExcluded() throws {
        var f=try fixture(); f.window(0,rise:-300,set:0); f.window(1,rise:60,set:360,elevation:19); f.window(2,rise:600,set:500)
        XCTAssertNil(f.result())
        f.window(2,rise:60,set:360,elevation:90)
        XCTAssertEqual(f.result()?.satellite.id,f.satellites[2].id)
    }
    func testMissingStaleAndReplacedElementsAreExcluded() throws {
        var f=try fixture(); f.window(0,rise:60,set:360)
        let id=f.satellites[0].id,value=try XCTUnwrap(f.elements[id])
        f.elements[id]=nil; XCTAssertNil(f.result())
        f.elements[id]=value
        f.date=f.date.addingTimeInterval(4*86400); f.window(0,rise:60,set:360)
        XCTAssertNil(f.result())
        f=try fixture(); f.window(0,rise:60,set:360)
        f.elements[id]?.fetchedAt=f.date.addingTimeInterval(10)
        XCTAssertNil(f.result(),"A prediction must correspond to the exact currently loaded elements")
    }
    func testObserverMaskAndMissingPredictionContextAreExcluded() throws {
        var f=try fixture(); f.window(0,rise:60,set:360)
        XCTAssertNil(f.result(observer:nil)); XCTAssertNil(f.result(mask:25))
        XCTAssertNil(f.result(observer:Observer(latitude:0,longitude:0,altitudeM:0)))
        XCTAssertNil(f.result(observer:Observer(latitude:.nan,longitude:0,altitudeM:0)))
        f.contexts=[:]; XCTAssertNil(f.result())
    }
    @MainActor func testAutomaticSelectionPausesDuringNavigationAndCalculation() {
        let old=UserDefaults.standard.object(forKey:"autoSelectSatellite")
        defer {
            if let old { UserDefaults.standard.set(old,forKey:"autoSelectSatellite") }
            else { UserDefaults.standard.removeObject(forKey:"autoSelectSatellite") }
        }
        let model=AppModel(); model.autoSelectSatellite=true
        XCTAssertTrue(model.automaticSelectionAllowed)
        model.pointing=true; XCTAssertFalse(model.automaticSelectionAllowed); model.pointing=false
        model.orbitPresented=true; XCTAssertFalse(model.automaticSelectionAllowed); model.orbitPresented=false
        model.scannerPresented=true; XCTAssertFalse(model.automaticSelectionAllowed); model.scannerPresented=false
        model.homePanel = .satellites; XCTAssertFalse(model.automaticSelectionAllowed); model.homePanel=nil
        model.calculatingSessions=true; XCTAssertFalse(model.automaticSelectionAllowed); model.calculatingSessions=false
        model.autoSelectSatellite=false; XCTAssertFalse(model.automaticSelectionAllowed)
        XCTAssertFalse(UserDefaults.standard.bool(forKey:"autoSelectSatellite"))
    }
    @MainActor func testCompleteLocalCatalogueUnblocksAutoBeforeRemoteRefreshEnds() {
        let old=UserDefaults.standard.object(forKey:"autoSelectSatellite")
        defer {
            if let old { UserDefaults.standard.set(old,forKey:"autoSelectSatellite") }
            else { UserDefaults.standard.removeObject(forKey:"autoSelectSatellite") }
        }
        let model=AppModel(); model.autoSelectSatellite=true
        model.beginLocalSessionCalculation()
        XCTAssertFalse(model.automaticSelectionAllowed)
        model.completeLocalSessionCalculation()
        XCTAssertTrue(model.calculatingSessions,"Remote refresh remains in progress")
        XCTAssertTrue(model.automaticSelectionAllowed,"Completed local windows must not wait for the network")
        model.pointing=true
        XCTAssertFalse(model.automaticSelectionAllowed)
        model.pointing=false
        model.beginLocalSessionCalculation()
        XCTAssertFalse(model.automaticSelectionAllowed,"A changed context must wait for the next full local calculation")
    }
}
