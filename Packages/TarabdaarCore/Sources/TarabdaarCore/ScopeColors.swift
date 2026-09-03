import SwiftUI

/// Shared scope colour scales. ONE level ramp for every scope on both
/// devices — the Mac Scope tab's sounding-string trajectories and the
/// iPad strike scope's onset fade — so "how loud / how fresh" reads the
/// same everywhere: **magma** (black → violet → magenta → orange → pale
/// yellow), perceptually uniform and legible on the dark grounds the
/// scopes use.
public enum ScopeColor {
    /// Matplotlib's magma, Matt Zucker's 6th-order polynomial fit
    /// (max error < 1/255 per channel). `t` 0…1, clamped.
    public static func magmaRGB(_ t: Double) -> (r: Double, g: Double, b: Double) {
        let x = min(1, max(0, t))
        let c0 = (-0.002136485053939582, -0.000749655052795221, -0.005386127855323933)
        let c1 = (0.2516605407371642, 0.6775232436837668, 2.494026599312351)
        let c2 = (8.353717279216625, -3.577719514958484, 0.3144679030132573)
        let c3 = (-27.66873308576866, 14.26473078096533, -13.68926264731113)
        let c4 = (52.17613981234068, -27.94360607168351, 12.94416944238394)
        let c5 = (-50.76852536473588, 29.04658282127291, 4.23415299384598)
        let c6 = (18.65570506591883, -11.48977351997711, -5.601961508734096)
        func poly(_ a: Double, _ b: Double, _ c: Double, _ d: Double,
                  _ e: Double, _ f: Double, _ g: Double) -> Double {
            a + x * (b + x * (c + x * (d + x * (e + x * (f + x * g)))))
        }
        return (min(1, max(0, poly(c0.0, c1.0, c2.0, c3.0, c4.0, c5.0, c6.0))),
                min(1, max(0, poly(c0.1, c1.1, c2.1, c3.1, c4.1, c5.1, c6.1))),
                min(1, max(0, poly(c0.2, c1.2, c2.2, c3.2, c4.2, c5.2, c6.2))))
    }

    public static func magma(_ t: Double) -> Color {
        let c = magmaRGB(t)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// The level ramp: magma with its darkest 18 % floored off so a
    /// barely-sounding trace still shows against the ground.
    public static func level(_ level01: Double) -> Color {
        magma(0.18 + 0.82 * min(1, max(0, level01)))
    }
}
