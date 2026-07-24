import Foundation
import Testing

@testable import macToolKit

/// Sunrise/sunset must land on the local calendar day it was asked about, in
/// every timezone — the algorithm computes a UTC hour-of-day, and anchoring
/// that to the wrong UTC day silently shifts an event by 24 h.
struct SolarTests {
    private struct City {
        let name: String
        let timeZone: String
        let latitude: Double
        let longitude: Double
        /// Expected local sunrise/sunset hour, to within `tolerance`.
        let sunriseHour: Double
        let sunsetHour: Double
    }

    /// Spread across the offset/longitude mismatch that broke the old
    /// anchoring: far-west-of-UTC (Americas), far-east (Japan), and the
    /// middle band that happened to work.
    private static let cities = [
        City(name: "Los Angeles", timeZone: "America/Los_Angeles",
             latitude: 34.05, longitude: -118.24, sunriseHour: 5.97, sunsetHour: 20.05),
        City(name: "New York", timeZone: "America/New_York",
             latitude: 40.71, longitude: -74.01, sunriseHour: 5.75, sunsetHour: 20.32),
        City(name: "Sao Paulo", timeZone: "America/Sao_Paulo",
             latitude: -23.55, longitude: -46.63, sunriseHour: 6.75, sunsetHour: 17.67),
        City(name: "London", timeZone: "Europe/London",
             latitude: 51.51, longitude: -0.13, sunriseHour: 5.18, sunsetHour: 21.02),
        City(name: "Berlin", timeZone: "Europe/Berlin",
             latitude: 52.52, longitude: 13.40, sunriseHour: 5.22, sunsetHour: 21.18),
        City(name: "Hyderabad", timeZone: "Asia/Kolkata",
             latitude: 17.39, longitude: 78.49, sunriseHour: 5.87, sunsetHour: 18.87),
        City(name: "Tokyo", timeZone: "Asia/Tokyo",
             latitude: 35.68, longitude: 139.69, sunriseHour: 4.70, sunsetHour: 18.87),
        City(name: "Auckland", timeZone: "Pacific/Auckland",
             latitude: -36.85, longitude: 174.76, sunriseHour: 7.55, sunsetHour: 17.35),
    ]

    private static func calendar(_ timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private static func date(_ calendar: Calendar,
                             year: Int, month: Int, day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour))!
    }

    /// Local hour-of-day as a fraction, e.g. 20:30 -> 20.5.
    private static func localHour(_ date: Date, _ calendar: Calendar) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Double(parts.hour!) + Double(parts.minute!) / 60
    }

    @Test("Sun times fall on the local day they were requested for",
          arguments: [1, 6, 12, 18, 23])
    func timesStayOnTheRequestedLocalDay(hour: Int) throws {
        for city in Self.cities {
            let calendar = Self.calendar(city.timeZone)
            let now = Self.date(calendar, year: 2026, month: 7, day: 24, hour: hour)
            let times = try #require(Solar.times(for: now,
                                                 latitude: city.latitude,
                                                 longitude: city.longitude,
                                                 calendar: calendar))

            #expect(calendar.isDate(times.sunrise, inSameDayAs: now),
                    "\(city.name) at \(hour):00 - sunrise on the wrong local day")
            #expect(calendar.isDate(times.sunset, inSameDayAs: now),
                    "\(city.name) at \(hour):00 - sunset on the wrong local day")
            #expect(times.sunrise < times.sunset,
                    "\(city.name) at \(hour):00 - sunrise must precede sunset")
        }
    }

    @Test("Sun times match published values within 15 minutes")
    func timesMatchPublishedValues() throws {
        for city in Self.cities {
            let calendar = Self.calendar(city.timeZone)
            let now = Self.date(calendar, year: 2026, month: 7, day: 24, hour: 12)
            let times = try #require(Solar.times(for: now,
                                                 latitude: city.latitude,
                                                 longitude: city.longitude,
                                                 calendar: calendar))

            let tolerance = 0.25 // hours
            #expect(abs(Self.localHour(times.sunrise, calendar) - city.sunriseHour)
                        < tolerance,
                    "\(city.name) sunrise \(Self.localHour(times.sunrise, calendar))")
            #expect(abs(Self.localHour(times.sunset, calendar) - city.sunsetHour)
                        < tolerance,
                    "\(city.name) sunset \(Self.localHour(times.sunset, calendar))")
        }
    }

    /// The regression that motivated these tests: with the event anchored to
    /// the wrong UTC day, auto mode read "night" at every hour of the day.
    @Test("Auto mode reads daylight at midday and night after dark")
    func autoModeFollowsTheLocalDay() throws {
        let night = 3400.0
        for city in Self.cities {
            let calendar = Self.calendar(city.timeZone)
            let noon = Self.date(calendar, year: 2026, month: 7, day: 24, hour: 12)
            let times = try #require(Solar.times(for: noon,
                                                 latitude: city.latitude,
                                                 longitude: city.longitude,
                                                 calendar: calendar))

            let atNoon = ColorTemperatureController.targetKelvin(
                at: noon, sunrise: times.sunrise, sunset: times.sunset, night: night)
            #expect(atNoon == ColorTemperatureController.dayKelvin,
                    "\(city.name) midday should be full daylight, got \(atNoon)K")

            // An hour past sunset the fade has finished — full night warmth.
            let afterDark = times.sunset.addingTimeInterval(3600)
            let atNight = ColorTemperatureController.targetKelvin(
                at: afterDark, sunrise: times.sunrise, sunset: times.sunset,
                night: night)
            #expect(atNight == night,
                    "\(city.name) after dark should be full night, got \(atNight)K")

            // An hour before sunrise the morning fade hasn't started yet.
            let beforeDawn = times.sunrise.addingTimeInterval(-3600)
            let atDawn = ColorTemperatureController.targetKelvin(
                at: beforeDawn, sunrise: times.sunrise, sunset: times.sunset,
                night: night)
            #expect(atDawn == night,
                    "\(city.name) before dawn should be full night, got \(atDawn)K")
        }
    }

    @Test("Fade interpolates in mired space and clamps at both ends")
    func fadeClampsAndInterpolates() {
        #expect(ColorTemperatureController.fade(from: 3400, to: 6500, progress: 0) == 3400)
        #expect(ColorTemperatureController.fade(from: 3400, to: 6500, progress: 1) == 6500)
        // Out-of-range progress must not overshoot past the endpoints.
        #expect(ColorTemperatureController.fade(from: 3400, to: 6500, progress: -5) == 3400)
        #expect(ColorTemperatureController.fade(from: 3400, to: 6500, progress: 5) == 6500)

        let midpoint = ColorTemperatureController.fade(
            from: 3400, to: 6500, progress: 0.5)
        #expect(midpoint > 3400 && midpoint < 6500)
        // Mired midpoint sits below the arithmetic mean of the two Kelvins.
        #expect(midpoint < (3400 + 6500) / 2)
    }

    @Test("Polar day and night report no sun times")
    func polarRegionsReturnNil() {
        let calendar = Self.calendar("UTC")
        let midsummer = Self.date(calendar, year: 2026, month: 6, day: 21, hour: 12)
        // Longyearbyen, Svalbard — midnight sun in June.
        #expect(Solar.times(for: midsummer, latitude: 78.22, longitude: 15.65,
                            calendar: calendar) == nil)
    }
}
