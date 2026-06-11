import Foundation

/// Sunrise/sunset via the NOAA simplified solar equation. Good to a couple of
/// minutes, which is plenty for scheduling a color-temperature fade.
enum Solar {
    struct Times {
        let sunrise: Date
        let sunset: Date
    }

    static func times(for date: Date, latitude: Double, longitude: Double,
                      calendar: Calendar = .current) -> Times? {
        guard let sunrise = event(sunrise: true, date: date,
                                  latitude: latitude, longitude: longitude,
                                  calendar: calendar),
              let sunset = event(sunrise: false, date: date,
                                 latitude: latitude, longitude: longitude,
                                 calendar: calendar)
        else { return nil }
        return Times(sunrise: sunrise, sunset: sunset)
    }

    private static func event(sunrise: Bool, date: Date,
                              latitude: Double, longitude: Double,
                              calendar: Calendar) -> Date? {
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let zenith = 90.833 // official sunrise/sunset
        let d2r = Double.pi / 180
        let r2d = 180 / Double.pi

        let lngHour = longitude / 15
        let t = sunrise
            ? dayOfYear + ((6 - lngHour) / 24)
            : dayOfYear + ((18 - lngHour) / 24)

        let m = (0.9856 * t) - 3.289
        var l = m + (1.916 * sin(m * d2r)) + (0.020 * sin(2 * m * d2r)) + 282.634
        l = l.truncatingRemainder(dividingBy: 360)
        if l < 0 { l += 360 }

        var ra = r2d * atan(0.91764 * tan(l * d2r))
        ra = ra.truncatingRemainder(dividingBy: 360)
        if ra < 0 { ra += 360 }
        let lQuadrant = floor(l / 90) * 90
        let raQuadrant = floor(ra / 90) * 90
        ra = (ra + (lQuadrant - raQuadrant)) / 15

        let sinDec = 0.39782 * sin(l * d2r)
        let cosDec = cos(asin(sinDec))

        let cosH = (cos(zenith * d2r) - (sinDec * sin(latitude * d2r)))
            / (cosDec * cos(latitude * d2r))
        guard cosH <= 1, cosH >= -1 else { return nil } // polar day/night

        var h = sunrise ? 360 - r2d * acos(cosH) : r2d * acos(cosH)
        h /= 15

        let localT = h + ra - (0.06571 * t) - 6.622
        var utc = localT - lngHour
        utc = utc.truncatingRemainder(dividingBy: 24)
        if utc < 0 { utc += 24 }

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let startOfDayUTC = utcCalendar.startOfDay(for: date)
        return startOfDayUTC.addingTimeInterval(utc * 3600)
    }
}
