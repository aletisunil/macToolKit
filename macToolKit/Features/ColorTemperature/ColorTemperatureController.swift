import AppKit
import CoreLocation
import Combine

enum ColorTemperatureMode: String {
    case manual, auto
}

/// Drives GammaController either from the manual slider or from a
/// sunrise/sunset schedule. Reapplies after display reconfiguration and wake,
/// because macOS resets gamma tables on both.
@MainActor
final class ColorTemperatureController: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let dayKelvin: Double = 6500
    static let minKelvin: Double = 2700
    static let maxKelvin: Double = 6500
    static let transitionSeconds: TimeInterval = 30 * 60

    private let gamma = GammaController()
    private var timer: Timer?
    private var locationManager: CLLocationManager?
    private var reconfigCallbackRegistered = false
    private(set) var running = false

    @Published var mode: ColorTemperatureMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "colorTempMode")
            applyNow()
        }
    }

    /// Manual slider value; also the night target in auto mode.
    @Published var kelvin: Double {
        didSet {
            UserDefaults.standard.set(kelvin, forKey: "colorTempKelvin")
            applyNow()
        }
    }

    @Published var useLocation: Bool {
        didSet {
            UserDefaults.standard.set(useLocation, forKey: "colorTempUseLocation")
            if useLocation { requestLocation() }
        }
    }

    // Fallback schedule when no location: minutes from midnight.
    @Published var fallbackSunriseMinutes: Int {
        didSet { UserDefaults.standard.set(fallbackSunriseMinutes, forKey: "colorTempSunrise") }
    }
    @Published var fallbackSunsetMinutes: Int {
        didSet { UserDefaults.standard.set(fallbackSunsetMinutes, forKey: "colorTempSunset") }
    }

    private var location: CLLocationCoordinate2D? {
        didSet { applyNow() }
    }

    override init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "colorTempKelvin": 3400.0,
            "colorTempMode": ColorTemperatureMode.manual.rawValue,
            "colorTempUseLocation": false,
            "colorTempSunrise": 7 * 60,
            "colorTempSunset": 19 * 60,
        ])
        mode = ColorTemperatureMode(rawValue: defaults.string(forKey: "colorTempMode") ?? "") ?? .manual
        kelvin = defaults.double(forKey: "colorTempKelvin")
        useLocation = defaults.bool(forKey: "colorTempUseLocation")
        fallbackSunriseMinutes = defaults.integer(forKey: "colorTempSunrise")
        fallbackSunsetMinutes = defaults.integer(forKey: "colorTempSunset")
        super.init()
    }

    func start() {
        guard !running else { return }
        running = true
        registerForDisplayChanges()
        if useLocation { requestLocation() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                AppState.shared.colorTemperature.applyNow()
            }
        }
        applyNow()
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        gamma.restore()
    }

    func applyNow() {
        guard running else { return }
        gamma.apply(kelvin: targetKelvin(at: Date()))
    }

    /// Day → 6500K; night → slider kelvin; linear fade over the 30 min after
    /// sunset start / before sunrise end.
    func targetKelvin(at date: Date) -> Double {
        guard mode == .auto else { return kelvin }

        let (sunrise, sunset) = scheduleTimes(for: date)
        let night = kelvin
        let day = Self.dayKelvin
        let fade = Self.transitionSeconds

        if date < sunrise || date >= sunset.addingTimeInterval(fade) {
            // deep night (also covers post-sunset fade completion)
            if date >= sunrise.addingTimeInterval(-fade), date < sunrise {
                let progress = 1 - (sunrise.timeIntervalSince(date) / fade)
                return Self.fade(from: night, to: day, progress: progress)
            }
            return night
        }
        if date >= sunset {
            let progress = date.timeIntervalSince(sunset) / fade
            return Self.fade(from: day, to: night, progress: progress)
        }
        return day
    }

    /// Interpolate color temperature in mired (reciprocal-Kelvin) space, which is
    /// perceptually linear. Interpolating Kelvin directly makes the fade look
    /// fast-then-slow; mired keeps the visible shift even across the transition.
    static func fade(from: Double, to: Double, progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        let mFrom = 1_000_000 / from
        let mTo = 1_000_000 / to
        return 1_000_000 / (mFrom + (mTo - mFrom) * t)
    }

    private func scheduleTimes(for date: Date) -> (sunrise: Date, sunset: Date) {
        if useLocation, let location,
           let times = Solar.times(for: date, latitude: location.latitude,
                                   longitude: location.longitude) {
            return (times.sunrise, times.sunset)
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        return (start.addingTimeInterval(Double(fallbackSunriseMinutes) * 60),
                start.addingTimeInterval(Double(fallbackSunsetMinutes) * 60))
    }

    // MARK: Display + wake reapply

    private func registerForDisplayChanges() {
        // Registered once for the controller's lifetime; applyNow() is a no-op
        // while stopped, so the observers are harmless when the feature is off.
        guard !reconfigCallbackRegistered else { return }
        reconfigCallbackRegistered = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func systemDidWake() {
        // Gamma tables are reset by the system; reapply shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.applyNow()
        }
    }

    // MARK: Location (one-shot, optional)

    private func requestLocation() {
        if locationManager == nil {
            let manager = CLLocationManager()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            locationManager = manager
        }
        locationManager?.requestWhenInUseAuthorization()
        locationManager?.requestLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor in
            self.location = coordinate
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // Fall back to fixed schedule; nothing to do.
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorized || status == .authorizedAlways,
               self.useLocation {
                self.locationManager?.requestLocation()
            }
        }
    }
}
