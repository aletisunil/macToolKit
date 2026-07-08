import AppKit
import CoreGraphics

/// Applies a color-temperature tint by scaling each display's *own* calibrated
/// gamma ramp per channel. Uses only public CoreGraphics API; macOS resets gamma
/// on display reconfiguration and wake, so callers must reapply (see
/// ColorTemperatureController).
@MainActor
final class GammaController {
    private(set) var currentKelvin: Double?

    private struct GammaRamp {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
        var size: Int
    }

    /// The display's original (calibrated, untinted) ramp, captured once before
    /// we ever tint it. Every apply scales from this baseline instead of reading
    /// back the hardware table - otherwise repeated applies would compound the
    /// tint on top of an already-tinted table.
    private var baselines: [CGDirectDisplayID: GammaRamp] = [:]

    func apply(kelvin: Double) {
        currentKelvin = kelvin
        let (wr, wg, wb) = Self.whitepoint(kelvin: kelvin)

        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        for display in displays {
            guard let base = baseline(for: display) else { continue }
            let n = base.size
            var red = [CGGammaValue](repeating: 0, count: n)
            var green = [CGGammaValue](repeating: 0, count: n)
            var blue = [CGGammaValue](repeating: 0, count: n)
            for i in 0..<n {
                red[i] = base.red[i] * Float(wr)
                green[i] = base.green[i] * Float(wg)
                blue[i] = base.blue[i] * Float(wb)
            }
            CGSetDisplayTransferByTable(display, UInt32(n), red, green, blue)
        }
    }

    /// Reads and caches the display's current ramp. Called before the first tint
    /// of a display (and after wake/reconfig the system has already reset the
    /// hardware to calibrated), so the captured table is the untinted baseline.
    private func baseline(for display: CGDirectDisplayID) -> GammaRamp? {
        if let cached = baselines[display] { return cached }
        let capacity = Int(CGDisplayGammaTableCapacity(display))
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: capacity)
        var green = [CGGammaValue](repeating: 0, count: capacity)
        var blue = [CGGammaValue](repeating: 0, count: capacity)
        var sampleCount: UInt32 = 0
        let err = CGGetDisplayTransferByTable(display, UInt32(capacity),
                                              &red, &green, &blue, &sampleCount)
        guard err == .success, sampleCount > 0 else { return nil }
        let n = Int(sampleCount)
        let ramp = GammaRamp(red: Array(red[0..<n]),
                             green: Array(green[0..<n]),
                             blue: Array(blue[0..<n]), size: n)
        baselines[display] = ramp
        return ramp
    }

    func restore() {
        currentKelvin = nil
        // Drop cached baselines: the next run must re-capture, since calibration
        // (or the set of connected displays) may have changed while we were off.
        baselines.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }

    /// Blackbody RGB multipliers (Tanner Helland approximation, as used by
    /// Redshift/f.lux-alikes). Returns channel scales normalized to 0...1.
    nonisolated static func whitepoint(kelvin: Double) -> (r: Double, g: Double, b: Double) {
        let t = min(max(kelvin, 1000), 12000) / 100

        let r: Double
        if t <= 66 {
            r = 255
        } else {
            r = 329.698727446 * pow(t - 60, -0.1332047592)
        }

        let g: Double
        if t <= 66 {
            g = 99.4708025861 * log(t) - 161.1195681661
        } else {
            g = 288.1221695283 * pow(t - 60, -0.0755148492)
        }

        let b: Double
        if t >= 66 {
            b = 255
        } else if t <= 19 {
            b = 0
        } else {
            b = 138.5177312231 * log(t - 10) - 305.0447927307
        }

        func clamp(_ v: Double) -> Double { min(max(v / 255, 0), 1) }
        return (clamp(r), clamp(g), clamp(b))
    }
}
