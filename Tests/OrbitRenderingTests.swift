import XCTest
import SceneKit
@testable import PloitSatellite

final class OrbitRenderingTests: XCTestCase {
    func testMonotonicPlaybackClockRatesPauseAndEnd() {
        let start=Date(timeIntervalSince1970:1000)
        for rate in [1.0,60,300] {
            let clock=OrbitClock(date:start,uptime:20,rate:rate,limit:start.addingTimeInterval(10000))
            XCTAssertEqual(clock.value(at:20.25).timeIntervalSince(start),rate*0.25,accuracy:0.00001)
            // Frame spacing is independent of the half-second SwiftUI timer.
            XCTAssertEqual(clock.value(at:20+1.0/120).timeIntervalSince(start),rate/120,accuracy:0.00001)
            let paused=OrbitClock(date:clock.value(at:21),uptime:21,rate:0)
            XCTAssertEqual(paused.value(at:500),paused.date)
            XCTAssertEqual(clock.value(at:50000),clock.limit)
        }
    }
    func testSolarSeasonsAndNightSideFollowUTC() throws {
        let format=ISO8601DateFormatter()
        for (time,declination) in [("2026-03-20T14:46:00Z",0.0),("2026-06-21T08:24:00Z",23.44),("2026-12-21T20:50:00Z",-23.44)] {
            let date=try XCTUnwrap(format.date(from:time)),sun=SolarPosition.direction(at:date)
            XCTAssertEqual(asin(sun.z)*180 / .pi,declination,accuracy:0.35)
            XCTAssertEqual(sun.x*sun.x+sun.y*sun.y+sun.z*sun.z,1,accuracy:1e-12)
        }
        let noon=try XCTUnwrap(format.date(from:"2026-03-20T12:00:00Z"))
        let a=SolarPosition.direction(at:noon),b=SolarPosition.direction(at:noon.addingTimeInterval(12*3600))
        XCTAssertGreaterThan(a.x,0.99) // Greenwich faces the Sun near noon at equinox.
        XCTAssertLessThan(b.x,-0.99)
        XCTAssertLessThan(a.x*b.x+a.y*b.y+a.z*b.z,-0.99)
    }
    @MainActor func testRefreshRatePolicySupportsProMotionAndFallbacks() {
        XCTAssertEqual(EarthRenderView.targetFPS(maximum:120,lowPower:false,thermal:.nominal),120)
        XCTAssertEqual(EarthRenderView.targetFPS(maximum:60,lowPower:false,thermal:.nominal),60)
        XCTAssertEqual(EarthRenderView.targetFPS(maximum:120,lowPower:true,thermal:.nominal),30)
        XCTAssertEqual(EarthRenderView.targetFPS(maximum:120,lowPower:false,thermal:.serious),30)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey:"CADisableMinimumFrameDurationOnPhone") as? Bool,true)
    }
    func testBufferedMotionMatchesSGP4BetweenSamplesAndAcrossDateline() async throws {
        let url=try XCTUnwrap(Bundle.main.url(forResource:"seed-tle",withExtension:"json"))
        let tle=try XCTUnwrap(JSONDecoder().decode([Elements].self,from:Data(contentsOf:url)).first)
        let date=try XCTUnwrap(tle.epoch),engine=OrbitEngine()
        let track=try await engine.motion(elements:tle,date:date,seconds:3600)
        XCTAssertEqual(track.samples.count,721)
        for t in [0.25,2.5,302.5,1797.5,3597.5] {
            let instant=date.addingTimeInterval(t),actual=try XCTUnwrap(track.state(at:instant))
            let expected=try await engine.state(elements:tle,date:instant)
            let p=actual.position,q=expected.position
            XCTAssertLessThan(sqrt(pow(p.x-q.x,2)+pow(p.y-q.y,2)+pow(p.z-q.z,2)),0.05)
        }
        XCTAssertNil(track.state(at:date.addingTimeInterval(-1)))
        XCTAssertNil(track.state(at:date.addingTimeInterval(3601)))
        var a=track.samples[0],b=a; a.longitude=179; b.longitude = -179
        let wrap=OrbitMotion(start:date,step:5,samples:[a,b])
        XCTAssertEqual(abs(try XCTUnwrap(wrap.state(at:date.addingTimeInterval(2.5))).longitude),180,accuracy:0.001)
    }
    func testCancelledOrbitRequestsDoNotStartPropagation() async throws {
        let engine=OrbitEngine()
        // An invalid TLE proves cancellation is checked before entering JavaScript.
        let invalid=Elements(norad:0,line1:"",line2:"",fetchedAt:Date())
        for operation in 0..<5 {
            let task=Task { () -> Bool in
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    switch operation {
                    case 0: _ = try await engine.look(elements:invalid,observer:.preview,date:Date())
                    case 1: _ = try await engine.passes(elements:invalid,observer:.preview,date:Date(),minElevation:10)
                    case 2: _ = try await engine.state(elements:invalid,date:Date())
                    case 3: _ = try await engine.trajectory(elements:invalid,date:Date())
                    default: _ = try await engine.motion(elements:invalid,date:Date(),seconds:3600)
                    }
                    return false
                } catch is CancellationError { return true }
                catch { return false }
            }
            let cancelled=await task.value
            XCTAssertTrue(cancelled,"Operation \(operation) must reject a cancelled request before propagation")
        }
        let url=try XCTUnwrap(Bundle.main.url(forResource:"seed-tle",withExtension:"json"))
        let tle=try XCTUnwrap(JSONDecoder().decode([Elements].self,from:Data(contentsOf:url)).first)
        let state=try await engine.state(elements:tle,date:try XCTUnwrap(tle.epoch))
        XCTAssertTrue(state.altitudeKm.isFinite)
        XCTAssertGreaterThan(state.altitudeKm,100)
    }
    @MainActor func testRenderFeedStopsImmediatelyAndCanRestart() {
        let feed=OrbitRenderFeed(),date=Date(timeIntervalSince1970:1000)
        let state=OrbitalState(position:OrbitPoint(x:7000,y:0,z:0),latitude:0,longitude:0,altitudeKm:622,periodSeconds:5400)
        let motion=OrbitMotion(start:date,step:5,samples:[state,state])
        feed.update(clock:OrbitClock(date:date),tracks:[25544:motion])
        var stopped=false
        feed.onStop = {
            XCTAssertFalse(feed.snapshot().active)
            XCTAssertTrue(feed.snapshot().tracks.isEmpty)
            stopped=true
        }
        feed.stop()
        XCTAssertTrue(stopped,"Closing must stop rendering synchronously, before cover dismissal")
        feed.update(clock:OrbitClock(date:date),tracks:[25544:motion])
        XCTAssertTrue(feed.snapshot().active)
        XCTAssertEqual(feed.snapshot().tracks.count,1)
    }
    @MainActor func testSceneEqualitySkipsMotionButPreservesVisibleChanges() {
        let date=Date(timeIntervalSince1970:1000),feed=OrbitRenderFeed()
        let state=OrbitalState(position:OrbitPoint(x:7000,y:0,z:0),latitude:0,longitude:0,altitudeKm:622,periodSeconds:5400)
        let scene=OrbitScene(states:[25544:state],paths:[:],pathDates:[:],ids:[25544],labels:[25544:"ISS"],
                             selectedID:25544,showAll:true,observer:.preview,focus:0,renderFeed:feed,
                             contentInsets:.zero,onInteraction:{ _ in },onSelect:{ _ in })
        var moved=scene
        moved.states[25544]?.position=OrbitPoint(x:6990,y:100,z:200)
        XCTAssertTrue(scene == moved,"The display-link feed updates positions without rebuilding the SwiftUI scene")
        let changes: [(inout OrbitScene)->Void] = [
            { $0.selectedID=59112 }, { $0.showAll=false }, { $0.focus=1 },
            { $0.ids.append(59112) }, { $0.labels[25544]="ISS\n12:00–12:04" },
            { $0.observer=nil }, { $0.contentInsets.top=80 },
            { $0.pathDates[25544]=date }, { $0.states=[:] }, { $0.renderFeed=OrbitRenderFeed() }
        ]
        for (index,change) in changes.enumerated() {
            var changed=scene; change(&changed)
            XCTAssertFalse(scene == changed,"Visible change \(index) must reach the SceneKit view")
        }
    }
    @MainActor func testPausedSceneAcceptsRevisedMotionAtSameDateAndStopsAdvancing() {
        let date=Date(timeIntervalSince1970:1000),feed=OrbitRenderFeed()
        let view=SCNView(),scene=SCNScene(),globe=SCNNode(),camera=SCNNode(),marker=SCNNode()
        camera.camera=SCNCamera()
        scene.rootNode.addChildNode(globe); scene.rootNode.addChildNode(camera); scene.rootNode.addChildNode(marker)
        view.scene=scene; view.pointOfView=camera
        let coordinator=OrbitScene.Coordinator()
        coordinator.view=view; coordinator.globe=globe; coordinator.feed=feed; coordinator.markers[25544]=marker
        let a=OrbitalState(position:OrbitPoint(x:7000,y:0,z:0),latitude:0,longitude:0,altitudeKm:622,periodSeconds:5400)
        var b=a; b.position=OrbitPoint(x:6900,y:1000,z:200)
        feed.update(clock:OrbitClock(date:date),tracks:[25544:OrbitMotion(start:date,step:5,samples:[a,a])])
        coordinator.updateFrame()
        XCTAssertEqual(marker.position.x,a.position.sceneX,accuracy:0.000001)
        feed.update(clock:OrbitClock(date:date),tracks:[25544:OrbitMotion(start:date,step:5,samples:[b,b])])
        coordinator.updateFrame()
        XCTAssertEqual(marker.position.x,b.position.sceneX,accuracy:0.000001)
        XCTAssertEqual(marker.position.y,b.position.sceneY,accuracy:0.000001)
        // A moving clock samples inside the same five-second buffer.
        let clock=OrbitClock(date:date,uptime:ProcessInfo.processInfo.systemUptime-5,rate:1,limit:date.addingTimeInterval(2.5))
        feed.update(clock:clock,tracks:[25544:OrbitMotion(start:date,step:5,samples:[a,b])])
        coordinator.updateFrame()
        XCTAssertEqual(marker.position.x,(a.position.sceneX+b.position.sceneX)/2,accuracy:0.000001)
        feed.stop()
        marker.position=SCNVector3(10,20,30)
        coordinator.updateFrame(force:true)
        XCTAssertEqual(marker.position.x,10)
        XCTAssertEqual(marker.position.y,20)
        XCTAssertEqual(marker.position.z,30)
    }
    @MainActor func testStopInvalidatesPendingResultsAndReopenWorks() async throws {
        let url=try XCTUnwrap(Bundle.main.url(forResource:"seed-tle",withExtension:"json"))
        let tle=try XCTUnwrap(JSONDecoder().decode([Elements].self,from:Data(contentsOf:url)).first)
        let date=try XCTUnwrap(tle.epoch),playback=OrbitPlayback()
        playback.configure(elements:[tle.norad:tle],selectedID:tle.norad,initialDate:date)
        playback.speed=300; playback.togglePlayback(); playback.scrub(600)
        playback.stop()
        let stopped=playback.date
        for _ in 0..<4 { playback.pulse(); playback.calculate(); try await Task.sleep(nanoseconds:50_000_000) }
        XCTAssertEqual(playback.date,stopped); XCTAssertFalse(playback.active)
        XCTAssertFalse(playback.renderFeed.snapshot().active)
        XCTAssertTrue(playback.renderFeed.snapshot().tracks.isEmpty)
        playback.configure(elements:[tle.norad:tle],selectedID:tle.norad,initialDate:date)
        for _ in 0..<40 { if playback.states[tle.norad] != nil { break }; try await Task.sleep(nanoseconds:50_000_000) }
        XCTAssertNotNil(playback.states[tle.norad]); XCTAssertTrue(playback.active)
        playback.stop()
    }
    @MainActor func testModelOwnedPulseAdvancesAndStopsWithPlaybackLifecycle() async throws {
        let playback=OrbitPlayback(),start=Date(timeIntervalSince1970:1000)
        for _ in 0..<2 {
            playback.configure(elements:[:],selectedID:25544,initialDate:start)
            playback.speed=300; playback.togglePlayback()
            for _ in 0..<60 {
                if playback.date.timeIntervalSince(start)>1 { break }
                try await Task.sleep(nanoseconds:50_000_000)
            }
            XCTAssertGreaterThan(playback.date.timeIntervalSince(start),1,"Time must advance without a view-owned timer")
            playback.stop()
            let stopped=playback.date
            try await Task.sleep(nanoseconds:700_000_000)
            XCTAssertEqual(playback.date,stopped,"Closing must cancel the periodic publisher before reopening")
        }
    }
}
