import XCTest
@testable import PloitSatellite

final class SiteWeatherTests: XCTestCase {
    func testTemperatureParsingKeepsMissingAndInvalidUnknown() {
        XCTAssertEqual(SiteWeather.parseTemperature(" −2,5 "), -2.5)
        XCTAssertEqual(SiteWeather.parseTemperature("0"), 0)
        for input in ["", "неизвестно", "NaN", "inf", "-91", "61"] {
            XCTAssertNil(SiteWeather.parseTemperature(input), input)
        }
    }

    func testFreshnessUsesObservationTimeAndFlagsUnexpectedFuture() {
        let date = Date(timeIntervalSince1970: 1792774800)
        let weather = SiteWeather(sampledAt: date, sky: .cloudy, wind: .unknown, temperatureC: nil)
        XCTAssertFalse(weather.isStale(at: date))
        XCTAssertFalse(weather.isStale(at: date.addingTimeInterval(3600)))
        XCTAssertTrue(weather.isStale(at: date.addingTimeInterval(3601)))
        XCTAssertTrue(weather.isStale(at: date.addingTimeInterval(-301)))
        XCTAssertNil(weather.outdoorAdvice)
    }

    func testWeatherAdviceDoesNotTurnCloudsIntoRadioObstruction() {
        let date = Date(timeIntervalSince1970: 1792774800)
        for sky in [SiteSkyCondition.clear, .cloudy, .fog, .unknown] {
            XCTAssertNil(SiteWeather(sampledAt: date, sky: sky, wind: .calm, temperatureC: 10).outdoorAdvice)
        }
        XCTAssertNotNil(SiteWeather(sampledAt: date, sky: .rain, wind: .calm, temperatureC: -2).outdoorAdvice)
        XCTAssertNotNil(SiteWeather(sampledAt: date, sky: .thunderstorm, wind: .calm, temperatureC: 20).outdoorAdvice)
        XCTAssertNotNil(SiteWeather(sampledAt: date, sky: .clear, wind: .strong, temperatureC: 20).outdoorAdvice)
    }

    @MainActor func testOnlyExplicitLocalRecordProducesWeatherAndRejectsEmptyObservation() {
        let service = SiteWeatherService()
        XCTAssertNil(service.weather)
        service.record(sky: .unknown, wind: .unknown, temperatureC: .nan)
        XCTAssertNil(service.weather)
        let date = Date(timeIntervalSince1970: 1792774800)
        service.record(sky: .snow, wind: .calm, temperatureC: -3, at: date)
        XCTAssertEqual(service.weather?.sampledAt, date)
        XCTAssertEqual(service.weather?.sky, .snow)
        XCTAssertEqual(service.weather?.temperatureC, -3)
        service.clear()
        XCTAssertNil(service.weather)
    }
}
