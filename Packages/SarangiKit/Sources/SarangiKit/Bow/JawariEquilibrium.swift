import Foundation

/// Build-time static contact equilibrium; a failed solve leaves the caller's settle fallback available.
enum JawariEquilibrium {
    static func solve(phi: [Double], force: [Double], omega: [Double],
                      bone: [Double], stiffness: Double, alpha: Double) -> [Double]? {
        let m = omega.count, j = bone.count
        guard m > 0, j > 0, phi.count == m*j, force.count == m*j,
              stiffness.isFinite, stiffness > 0, alpha.isFinite, alpha >= 1,
              bone.allSatisfy(\.isFinite),
              omega.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let scale = max(bone.map { abs($0) }.max() ?? 0, 1e-12)
        var compliance = [Double](repeating: 0, count: j*j)
        for a in 0..<j {
            for b in 0..<j {
                for k in 0..<m {
                    compliance[a*j+b] += phi[k*j+a] * force[k*j+b]
                        / (omega[k]*omega[k])
                }
            }
        }
        guard compliance.allSatisfy(\.isFinite) else { return nil }
        func forces(_ x: [Double]) -> [Double] {
            (0..<j).map { stiffness * pow(max(bone[$0] - scale*x[$0], 0), alpha) }
        }
        func residual(_ x: [Double]) -> [Double] {
            let f = forces(x)
            return (0..<j).map { a in
                var r = x[a]
                for b in 0..<j { r -= compliance[a*j+b] * f[b] / scale }
                return r
            }
        }
        var x = bone.map { max($0 / scale, 0) }
        var r = residual(x)
        for _ in 0..<80 {
            let norm = r.reduce(0) { $0 + $1*$1 }
            guard norm.isFinite else { return nil }
            if r.map({ abs($0) }).max()! < 1e-11 {
                let f = forces(x)
                var q = [Double](repeating: 0, count: m)
                for k in 0..<m {
                    for b in 0..<j { q[k] += force[k*j+b] * f[b] }
                    q[k] /= omega[k]*omega[k]
                }
                // Check the reconstructed modal state against the actual force
                // equation, rather than accepting a small Newton step alone.
                var actualForce = [Double](repeating: 0, count: j)
                for b in 0..<j {
                    var u = 0.0
                    for k in 0..<m { u += phi[k*j+b]*q[k] }
                    actualForce[b] = stiffness * pow(max(bone[b]-u, 0), alpha)
                }
                var error = 0.0, magnitude = 0.0
                for k in 0..<m {
                    var load = 0.0
                    for b in 0..<j { load += force[k*j+b]*actualForce[b] }
                    let restoring = omega[k]*omega[k]*q[k]
                    error += (restoring-load)*(restoring-load)
                    magnitude += restoring*restoring + load*load
                }
                return q.allSatisfy(\.isFinite) && error <= 1e-14*max(magnitude, 1e-30) ? q : nil
            }
            let derivative = (0..<j).map {
                stiffness * alpha * pow(max(bone[$0]-scale*x[$0], 0), alpha-1)
            }
            var jacobian = compliance
            for a in 0..<j {
                for b in 0..<j {
                    jacobian[a*j+b] *= derivative[b]
                    if a == b { jacobian[a*j+b] += 1 }
                }
            }
            guard let step = linearSolve(jacobian, r.map { -$0 }) else { return nil }
            var fraction = 1.0, accepted = false
            for _ in 0..<30 {
                let candidate = zip(x, step).map { $0 + fraction*$1 }
                let next = residual(candidate)
                if next.reduce(0, { $0 + $1*$1 }) < norm {
                    x = candidate; r = next; accepted = true; break
                }
                fraction *= 0.5
            }
            if !accepted { return nil }
        }
        return nil
    }

    private static func linearSolve(_ matrix: [Double], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var a = matrix, b = rhs
        for k in 0..<n {
            var pivot = k
            for i in k..<n where abs(a[i*n+k]) > abs(a[pivot*n+k]) { pivot = i }
            guard abs(a[pivot*n+k]) > 1e-30 else { return nil }
            if pivot != k {
                for j in k..<n { a.swapAt(k*n+j, pivot*n+j) }
                b.swapAt(k, pivot)
            }
            for i in (k+1)..<n {
                let multiplier = a[i*n+k] / a[k*n+k]
                for j in k..<n { a[i*n+j] -= multiplier*a[k*n+j] }
                b[i] -= multiplier*b[k]
            }
        }
        for i in stride(from: n-1, through: 0, by: -1) {
            for j in (i+1)..<n { b[i] -= a[i*n+j]*b[j] }
            b[i] /= a[i*n+i]
        }
        return b.allSatisfy(\.isFinite) ? b : nil
    }
}
