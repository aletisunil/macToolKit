import AppKit
import CoreGraphics

/// Applies a color-temperature tint by scaling per-channel gamma ramps on all
/// active displays. Uses only public CoreGraphics API; macOS resets gamma on
/// display reconfiguration and wake, so callers must reapply (see
/// ColorTemperatureController).
@MainActor
final class GammaController {
    private(set) var currentKelvin: Double?

    func apply(kelvin: Double) {
        currentKelvin = kelvin
        let (r, g, b) = Self.whitepoint(kelvin: kelvin)

        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        let tableSize = 256
        var red = [CGGammaValue](repeating: 0, count: tableSize)
        var green = [CGGammaValue](repeating: 0, count: tableSize)
        var blue = [CGGammaValue](repeating: 0, count: tableSize)
        for i in 0..<tableSize {
            let x = Float(i) / Float(tableSize - 1)
            red[i] = x * Float(r)
            green[i] = x * Float(g)
            blue[i] = x * Float(b)
        }
        for display in displays {
            CGSetDisplayTransferByTable(display, UInt32(tableSize), red, green, blue)
        }
    }

    func restore() {
        currentKelvin = nil
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
