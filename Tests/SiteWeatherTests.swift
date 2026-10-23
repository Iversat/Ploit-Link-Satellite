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
        XCTAssertNil(service.forecast)
        XCTAssertFalse(service.isLoading)
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

    func testForecastDecodesCurrentModelWithUTCAndMissingData() throws {
        let data = Data(#"{"current":{"time":1792774800,"interval":900,"temperature_2m":-2.5,"cloud_cover":70,"precipitation":0.2,"wind_speed_10m":4.8,"weather_code":73}}"#.utf8)
        let weather = try SiteWeatherAPI.decode(data)
        XCTAssertEqual(weather.sampledAt.timeIntervalSince1970, 1792774800)
        XCTAssertEqual(weather.interval, 900)
        XCTAssertEqual(weather.temperatureC, -2.5)
        XCTAssertEqual(weather.cloudCover, 70)
        XCTAssertEqual(weather.precipitationMM, 0.2)
        XCTAssertEqual(weather.windMS, 4.8)
        XCTAssertEqual(weather.observation.sky, .snow)
        XCTAssertNotNil(weather.observation.outdoorAdvice)
        XCTAssertFalse(weather.isStale(at: weather.sampledAt.addingTimeInterval(900)))
        XCTAssertTrue(weather.isStale(at: weather.sampledAt.addingTimeInterval(3601)))
        XCTAssertTrue(weather.isStale(at: weather.sampledAt.addingTimeInterval(-301)))

        let partial = try SiteWeatherAPI.decode(Data(#"{"current":{"time":1792774800,"temperature_2m":null,"cloud_cover":150,"wind_speed_10m":2,"precipitation":-1}}"#.utf8))
        XCTAssertNil(partial.temperatureC)
        XCTAssertNil(partial.cloudCover)
        XCTAssertNil(partial.precipitationMM)
        XCTAssertNil(partial.weatherCode)
        XCTAssertEqual(partial.windMS, 2)
        XCTAssertEqual(partial.interval, 900)
        XCTAssertEqual(partial.observation.sky, .unknown)
    }

    func testForecastRejectsMissingTimeAndEmptyMeasurements() {
        for json in [#"{"current":{"time":1792774800}}"#,
                     #"{"current":{"temperature_2m":20}}"#,
                     #"{"current":{"time":0,"temperature_2m":20}}"#,
                     #"{"error":true,"reason":"unavailable"}"#] {
            XCTAssertThrowsError(try SiteWeatherAPI.decode(Data(json.utf8)))
        }
    }

    func testOnlineRequestRoundsCoordinatesAndFixesUnitsAndUTC() throws {
        let observer = Observer(latitude: 48.708123, longitude: 44.513456, altitudeM: 123)
        let url = try SiteWeatherAPI.requestURL(observer: observer)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api.open-meteo.com")
        XCTAssertEqual(items["latitude"], "48.71")
        XCTAssertEqual(items["longitude"], "44.51")
        XCTAssertEqual(items["timezone"], "GMT")
        XCTAssertEqual(items["timeformat"], "unixtime")
        XCTAssertEqual(items["wind_speed_unit"], "ms")
        XCTAssertEqual(items["temperature_unit"], "celsius")
        XCTAssertEqual(items["precipitation_unit"], "mm")
        XCTAssertNil(items["elevation"])
        XCTAssertThrowsError(try SiteWeatherAPI.requestURL(observer: Observer(latitude: 91, longitude: 0, altitudeM: 0)))
        XCTAssertNil(SiteWeatherAPI.location(for: Observer(latitude: .nan, longitude: 0, altitudeM: 0)))
        XCTAssertNil(SiteWeatherAPI.location(for: nil))
    }

    @MainActor func testInvalidOnlineCoordinatesDoNotLoadAndManualRecordIsPreserved() {
        let service = SiteWeatherService()
        service.record(sky: .cloudy, wind: .calm, temperatureC: 10)
        service.load(observer: Observer(latitude: 0, longitude: 181, altitudeM: 0))
        XCTAssertFalse(service.isLoading)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertNil(service.forecast)
        XCTAssertEqual(service.weather?.sky, .cloudy)
        service.clear()
        XCTAssertNil(service.errorMessage)
    }
}
