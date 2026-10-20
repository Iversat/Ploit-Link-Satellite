import XCTest
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
}
