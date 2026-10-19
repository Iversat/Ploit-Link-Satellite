import XCTest
@testable import PloitSatellite

final class AimTests: XCTestCase {
    func testGlobeDragLocksAxisAndUsesGestureStartPose() {
        var camera=GlobeCamera(yaw:179,pitch:35,zoom:1.2),drag=GlobeDrag()
        drag.begin(camera)
        camera=drag.update(x:100,y:12,width:400)
        XCTAssertEqual(camera.pitch,35); XCTAssertEqual(camera.yaw,134)
        // Total gesture displacement must not be accumulated again on every event.
        camera=drag.update(x:100,y:100,width:400)
        XCTAssertEqual(camera.pitch,35); XCTAssertEqual(camera.yaw,134)
        drag.begin(camera)
        camera=drag.update(x:8,y:-50,width:400)
        XCTAssertEqual(camera.yaw,134); XCTAssertEqual(camera.pitch,12.5)
        XCTAssertEqual(camera.zoom,1.2)
        drag.begin(camera)
        XCTAssertEqual(drag.update(x:1,y:1,width:400).yaw,134)
    }
    func testRearReticleCentersAlignedTargetIncludingZenith() {
        for (az,el) in [(135.0,45.0),(0,90),(359,0)] {
            let basis=AimMath.pose(azimuth:az,elevation:el,aiming:.back)
            let p=RearAimProjection(azimuth:az,elevation:el,basis:basis)
            XCTAssertEqual(p.x,0,accuracy:0.000001); XCTAssertEqual(p.y,0,accuracy:0.000001)
            XCTAssertFalse(p.behind)
        }
    }
    func testRearReticleTracksScreenAxesRollAndOppositeHemisphere() {
        let basis=DeviceBasis(x:.init(north:0,west:-1,up:0),y:.init(north:0,west:0,up:1),z:.init(north:-1,west:0,up:0))
        let right=RearAimProjection(azimuth:20,elevation:0,basis:basis)
        XCTAssertGreaterThan(right.x,0); XCTAssertEqual(right.y,0,accuracy:0.000001)
        let up=RearAimProjection(azimuth:0,elevation:20,basis:basis)
        XCTAssertLessThan(up.y,0); XCTAssertEqual(up.x,0,accuracy:0.000001)
        let rolled=DeviceBasis(x:basis.y,y:basis.x.negative,z:basis.z)
        let roll=RearAimProjection(azimuth:20,elevation:0,basis:rolled)
        XCTAssertEqual(roll.x,0,accuracy:0.000001); XCTAssertGreaterThan(roll.y,0)
        let opposite=RearAimProjection(azimuth:180,elevation:0,basis:basis)
        XCTAssertTrue(opposite.behind); XCTAssertEqual(hypot(opposite.x,opposite.y),1,accuracy:0.000001)
        let closer=RearAimProjection(azimuth:5,elevation:0,basis:basis)
        XCTAssertLessThan(abs(closer.x),abs(right.x))
    }
    func testGlobeCameraFullRotationNoTranslationAndBoundedZoom() {
        var camera=GlobeCamera()
        camera.drag(x:200,y:0,width:400)
        XCTAssertEqual(camera.yaw,-90)
        camera.drag(x:0,y:10000,width:400)
        XCTAssertEqual(camera.pitch,85)
        camera.magnify(100); XCTAssertEqual(camera.zoom,1.65)
        camera.magnify(0.001); XCTAssertEqual(camera.zoom,0.8)
        let p=camera.unitPosition
        XCTAssertEqual(p.x*p.x+p.y*p.y+p.z*p.z,1,accuracy:0.000001)
    }
    func testKnownFlatPhoneAxes() {
        let basis = DeviceBasis(x:.init(north:0,west:-1,up:0),y:.init(north:1,west:0,up:0),z:.init(north:0,west:0,up:1))
        let top = AimMath.direction(axis:.top,basis:basis)
        let back = AimMath.direction(axis:.back,basis:basis)
        XCTAssertEqual(top.az,0,accuracy:0.000001)
        XCTAssertEqual(top.el,0,accuracy:0.000001)
        XCTAssertEqual(back.el,-90,accuracy:0.000001)
    }
    func testTwoPhysicalAxesStayOrthogonal() {
        for axis in AimAxis.allCases {
            for (az,el) in [(0.0,0.0),(135.0,45.0),(359.0,75.0),(180.0,-20.0)] {
                let basis = AimMath.pose(azimuth:az,elevation:el,aiming:axis)
                XCTAssertEqual(basis.x.dot(basis.y),0,accuracy:0.000001)
                XCTAssertEqual(basis.y.dot(basis.z),0,accuracy:0.000001)
                XCTAssertEqual(basis.x.cross(basis.y).dot(basis.z),1,accuracy:0.000001)
                let selected = AimMath.direction(axis:axis,basis:basis)
                XCTAssertEqual(AimMath.separation(az1:az,el1:el,az2:selected.az,el2:selected.el),0,accuracy:0.00001)
                let a = AimMath.direction(axis:.top,basis:basis), b = AimMath.direction(axis:.back,basis:basis)
                XCTAssertEqual(AimMath.separation(az1:a.az,el1:a.el,az2:b.az,el2:b.el),90,accuracy:0.000001)
            }
        }
    }
    func testBackUsesOutwardNegativeScreenZ() {
        let basis = AimMath.pose(azimuth:270,elevation:30,aiming:.back)
        let outward = basis.vector(for:.back)
        XCTAssertEqual(outward.dot(basis.z),-1,accuracy:0.000001)
        let direction = AimMath.direction(axis:.back,basis:basis)
        XCTAssertEqual(direction.az,270,accuracy:0.000001)
        XCTAssertEqual(direction.el,30,accuracy:0.000001)
    }
    @MainActor func testSwitchingAxisImmediatelyReprojectsSamePose() {
        let sensors = Sensors()
        sensors.preview(azimuth:135,elevation:45,axis:.top)
        let oldAz = sensors.azimuth, oldEl = sensors.elevation
        sensors.axis = .back
        XCTAssertTrue(sensors.motionReady)
        XCTAssertEqual(AimMath.separation(az1:oldAz,el1:oldEl,az2:sensors.azimuth,el2:sensors.elevation),90,accuracy:0.000001)
        sensors.axis = .top
        XCTAssertEqual(sensors.azimuth,135,accuracy:0.000001)
        XCTAssertEqual(sensors.elevation,45,accuracy:0.000001)
    }
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
    func testSessionWindowBoundariesAndExpiredPasses() {
        let passes=[PassWindow(rise:100,culmination:150,set:200,maxElevation:45,inProgress:false),PassWindow(rise:300,culmination:350,set:400,maxElevation:60,inProgress:false)]
        XCTAssertEqual(SessionText.window(passes,at:Date(timeIntervalSince1970:199))?.rise,100)
        XCTAssertEqual(SessionText.window(passes,at:Date(timeIntervalSince1970:200))?.rise,300)
        XCTAssertTrue(passes[0].contains(Date(timeIntervalSince1970:100)))
        XCTAssertFalse(passes[0].contains(Date(timeIntervalSince1970:200)))
        XCTAssertNil(SessionText.window(passes,at:Date(timeIntervalSince1970:400)))
    }
    func testSessionClockHasUnambiguous24HourTime() throws {
        let date=try XCTUnwrap(Calendar.current.date(from:DateComponents(year:2026,month:10,day:19,hour:18,minute:5,second:0)))
        XCTAssertEqual(SessionText.clock(date),"18:05")
        XCTAssertTrue(SessionText.timestamp(date).contains("18:05:00"))
    }
    func testMotionDirectionWrapsNorthAndIncludesElevation() {
        let current=Look(azimuth:359,elevation:40,rangeKm:1000,rangeRate:0,latitude:0,longitude:0,altitudeKm:400)
        var next=current; next.azimuth=1; next.elevation=45
        let motion=TrackingMotion(current:current,future:next)
        XCTAssertEqual(motion.bearingRate,0.2,accuracy:0.00001)
        XCTAssertEqual(motion.elevationRate,0.5,accuracy:0.00001)
        XCTAssertTrue(motion.instruction.contains("вправо")); XCTAssertTrue(motion.instruction.contains("выше"))
    }
    func testOrbitalSceneAxesAndTrajectoryMatchPosition() async throws {
        let url=try XCTUnwrap(Bundle.main.url(forResource:"seed-tle",withExtension:"json"))
        let entry=try XCTUnwrap(JSONDecoder().decode([Elements].self,from:Data(contentsOf:url)).first)
        let date=try XCTUnwrap(entry.epoch),engine=OrbitEngine()
        let state=try await engine.state(elements:entry,date:date)
        let look=try await engine.look(elements:entry,observer:.preview,date:date)
        let path=try await engine.trajectory(elements:entry,date:date)
        XCTAssertEqual(state.latitude,look.latitude,accuracy:0.000001)
        XCTAssertEqual(state.longitude,look.longitude,accuracy:0.000001)
        XCTAssertEqual(path.orbit.count,121); XCTAssertEqual(path.ground.count,121)
        XCTAssertEqual(path.orbit[60].x,state.position.x,accuracy:0.00001)
        XCTAssertEqual(path.orbit[60].y,state.position.y,accuracy:0.00001)
        let greenwich=OrbitPoint(x:6378.137,y:0,z:0)
        XCTAssertEqual(greenwich.sceneZ,1,accuracy:0.00001); XCTAssertEqual(greenwich.sceneX,0)
        XCTAssertTrue((5000...8000).contains(state.periodSeconds))
    }
    @MainActor func testLivePointingTargetMovesWithSatellite() async throws {
        let model=AppModel()
        let url=try XCTUnwrap(Bundle.main.url(forResource:"seed-tle",withExtension:"json"))
        let entry=try XCTUnwrap(JSONDecoder().decode([Elements].self,from:Data(contentsOf:url)).first)
        model.elements=entry; model.manualLocation=true; model.manualLat="48.708"; model.manualLon="44.513"
        let date=try XCTUnwrap(entry.epoch)
        await model.tick(at:date)
        let before=try XCTUnwrap(model.look)
        await model.tick(at:date.addingTimeInterval(60))
        let after=try XCTUnwrap(model.look),future=try XCTUnwrap(model.futureLook)
        XCTAssertGreaterThan(AimMath.separation(az1:before.azimuth,el1:before.elevation,az2:after.azimuth,el2:after.elevation),0.1)
        let expected=try await OrbitEngine().look(elements:entry,observer:try XCTUnwrap(model.observer),date:date.addingTimeInterval(70))
        XCTAssertEqual(future.azimuth,expected.azimuth,accuracy:0.000001)
        model.deactivate()
    }
    @MainActor func testOpeningForecastRecomputesCoordinatesWithSameElements() async throws {
        let url=try XCTUnwrap(Bundle.main.url(forResource:"seed-tle",withExtension:"json"))
        let tle=try XCTUnwrap(JSONDecoder().decode([Elements].self,from:Data(contentsOf:url)).first)
        let date=try XCTUnwrap(tle.epoch),playback=OrbitPlayback(),engine=OrbitEngine()
        playback.configure(elements:[tle.norad:tle],selectedID:tle.norad,initialDate:date)
        for _ in 0..<30 { if playback.states[tle.norad] != nil { break }; try await Task.sleep(nanoseconds:50_000_000) }
        XCTAssertNotNil(playback.states[tle.norad])
        let future=date.addingTimeInterval(3600)
        playback.configure(elements:[tle.norad:tle],selectedID:tle.norad,initialDate:future)
        for _ in 0..<30 { if playback.states[tle.norad] != nil { break }; try await Task.sleep(nanoseconds:50_000_000) }
        let actual=try XCTUnwrap(playback.states[tle.norad]),expected=try await engine.state(elements:tle,date:future)
        XCTAssertEqual(actual.latitude,expected.latitude,accuracy:0.000001)
        XCTAssertEqual(actual.longitude,expected.longitude,accuracy:0.000001)
        XCTAssertFalse(playback.live); playback.stop()
    }
}
