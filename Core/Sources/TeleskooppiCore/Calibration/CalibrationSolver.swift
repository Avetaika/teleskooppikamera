import Foundation

/// Solution of the calibration geometry (plan 4.4).
public struct CalibrationSolution: Sendable, Equatable {
    /// M = [m_R m_U] in px/s.
    public var stickToImage: Mat2
    /// Display rotation theta (radians, wrapped to (-pi, pi]).
    public var displayRotation: Double
    public var mirrored: Bool
    /// |angle(m_R, m_U) - 90 deg| in radians.
    public var orthogonalityError: Double
}

/// Pure calibration math (plan 4.4, 4.6). No state.
public enum CalibrationSolver {
    /// Target view E = [e_R e_U]: stick RIGHT moves stars screen-left, stick UP moves them
    /// screen-down (screen y down). det E = -1.
    public static let target = Mat2(columns: Vec2(-1, 0), Vec2(0, 1))

    /// `R(theta) F^k` with `F = diag(-1, 1)`: the linear part of the display transform.
    public static func displayMatrix(rotation: Double, mirrored: Bool) -> Mat2 {
        Mat2.rotation(rotation) * (mirrored ? Mat2.flipX : Mat2.identity)
    }

    /// |angle between a and b - 90 deg| in radians.
    public static func orthogonalityError(_ a: Vec2, _ b: Vec2) -> Double {
        abs(a.angle(to: b) - .pi / 2)
    }

    /// Solves rotation and mirror from the two measured image velocities.
    ///
    /// - Mirror: `mirrored = sign(det M) != sign(det E)`.
    /// - Rotation: `theta = circular mean(atan2(e_R) - atan2(a_R), atan2(e_U) - atan2(a_U))` with
    ///   `a = F^k m / |m|`: the 2D Procrustes solution for equally weighted unit vectors.
    ///
    /// Returns `nil` for zero-length or (anti)parallel inputs.
    public static func solve(mRight: Vec2, mUp: Vec2) -> CalibrationSolution? {
        guard mRight.length > 0, mUp.length > 0, mRight.isFinite, mUp.isFinite else { return nil }
        let m = Mat2(columns: mRight, mUp)
        let det = m.determinant
        // Parallel moves: no handedness and no meaningful rotation.
        guard abs(det) > 1e-9 * mRight.length * mUp.length else { return nil }
        let mirrored = (det > 0) != (target.determinant > 0)
        let f = mirrored ? Mat2.flipX : Mat2.identity
        let aR = (f * mRight).normalized
        let aU = (f * mUp).normalized
        let thetaR = target.column0.angle - aR.angle
        let thetaU = target.column1.angle - aU.angle
        guard let theta = AngleMath.circularMean([thetaR, thetaU]) else { return nil }
        return CalibrationSolution(stickToImage: m, displayRotation: AngleMath.wrapPi(theta), mirrored: mirrored,
                                   orthogonalityError: orthogonalityError(mRight, mUp))
    }

    /// Quick recalibration from a single UP move (D-06, plan 4.6).
    ///
    /// Assumes only the image rotation (phone angle in the adapter) and possibly the speed level
    /// changed since `previous`: m_R is derived by applying the same rotation and scale that maps the
    /// previous m_U to the new one. This keeps the previous mirror state, axis rate ratio and any
    /// residual non-orthogonality.
    public static func quickRecalibration(mUp: Vec2, previous: Mat2) -> CalibrationSolution? {
        let oldUp = previous.column1, oldRight = previous.column0
        guard oldUp.length > 0, mUp.length > 0 else { return nil }
        let rotation = oldUp.signedAngle(to: mUp)
        let scale = mUp.length / oldUp.length
        let mRight = oldRight.rotated(by: rotation) * scale
        return solve(mRight: mRight, mUp: mUp)
    }

    /// Screen-space motion direction (x right, y down) of the star for each stick direction under
    /// the given display matrix. With a correct calibration RIGHT gives (-1, 0) and UP gives (0, 1).
    public static func screenMotion(of direction: StickDirection, stickToImage: Mat2, display: Mat2) -> Vec2 {
        (display * (stickToImage * direction.unitVector)).normalized
    }
}
