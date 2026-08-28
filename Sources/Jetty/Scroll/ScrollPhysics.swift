import Foundation

/// Continuous scroll position in row units.
///
/// `position == 0` is the top of scrollback. `position == maxOffset` is pinned
/// to the active bottom. Motion stays inside `[0, maxOffset]`.
public final class ScrollPhysics {
    /// Continuous offset into the scrollable range (rows from top of history).
    private(set) var position: Double = 0
    /// Rows per second.
    private(set) var velocity: Double = 0
    /// When true, stick to the bottom as new output arrives.
    private(set) var pinnedToBottom: Bool = true

    var friction: Double = 2
    /// Decay for the active coast. Trackpad uses `friction`; wheel and page use 3×.
    private var coastFriction: Double = 2
    /// Page-key coast. Settle snaps to a whole row so floor() is not 1 off.
    private var pageCoast = false
    /// Starting visual cap (rows/frame). Grows with `runTime` until unrestricted.
    var maxRowsPerFrame: Double = 1.0
    /// Seconds for the cap to double. ~1.4s to pass 64 rows/frame.
    var accelHalflife: Double = 0.2

    private let settlePos: Double = 0.02
    private let settleVel: Double = 0.05
    /// Absolute row offset to ease toward (search / programmatic scroll). Nil = free physics.
    private var seekTarget: Double?
    /// ⌘End: chase the live bottom until we arrive. Output does not use this.
    private var seekFollowsBottom = false
    /// ⌘Home: chase the top of history until we arrive.
    private var seekFollowsTop = false
    /// Seconds of continuous scrollback motion. Zero after a real stop.
    private var runTime: Double = 0
    /// Monotonic time of the last physics tick. Used to count MTKView pauses as idle.
    private var lastTickAt: Double = 0
    var idleReset: Double = 0.25
    /// Tests replace this to simulate a paused view without sleeping.
    var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// Fingers still on the pad; `step` must not integrate (position already moved 1:1).
    private var fingerDown = false
    /// `NSEvent.timestamp` of the last precise delta, for finger velocity.
    private var lastPreciseAt: Double = 0

    /// Integer row for `GHOSTTY_SCROLL_VIEWPORT_ROW` (clamped into range).
    func integerRow(maxOffset: Double) -> UInt64 {
        let maxO = max(0, maxOffset)
        if position <= 0 { return 0 }
        if position >= maxO { return UInt64(maxO.rounded(.down)) }
        return UInt64(position.rounded(.down))
    }

    /// Fractional part in [0, 1). Pixel shift: `y += visualOffsetRows * cellHeight`.
    func visualOffsetRows(maxOffset: Double) -> Double {
        let maxO = max(0, maxOffset)
        let p = min(max(position, 0), maxO)
        let frac = p - floor(p)
        return -frac
    }

    /// Apply a wheel impulse.
    /// Positive `deltaRows` moves toward older history (position decreases toward 0).
    func applyImpulse(deltaRows: Double) {
        if abs(deltaRows) < 1e-9 { return }
        clearFingerTracking()
        resetAccelIfIdleOrChase()
        seekTarget = nil
        seekFollowsBottom = false
        seekFollowsTop = false
        pinnedToBottom = false
        pageCoast = false
        coastFriction = max(friction, 0.05) * 3
        velocity -= deltaRows * coastFriction
        runTime = max(runTime, 1.5)
        lastTickAt = now()
    }

    /// Trackpad/Magic Mouse finger motion. Position follows the delta 1:1.
    /// After `ended`, `step` coasts at the last finger speed.
    func applyPreciseDelta(deltaRows: Double, timestamp: Double, began: Bool, ended: Bool) {
        resetAccelIfIdleOrChase()
        seekTarget = nil
        seekFollowsBottom = false
        seekFollowsTop = false
        pinnedToBottom = false
        pageCoast = false
        coastFriction = max(friction, 0.05)
        runTime = max(runTime, 1.5)
        if began {
            lastPreciseAt = 0
            velocity = 0
        }
        if abs(deltaRows) >= 1e-9 {
            position -= deltaRows
            let dt = lastPreciseAt > 0 ? timestamp - lastPreciseAt : 0
            if dt > 1e-4, dt < 0.08 {
                velocity = -deltaRows / dt
            } else {
                velocity = -deltaRows * 120
            }
            lastPreciseAt = timestamp
        }
        if ended {
            fingerDown = false
            lastPreciseAt = 0
        } else {
            fingerDown = true
        }
    }

    /// Kill leftover velocity. Position and pin stay.
    func brake() {
        velocity = 0
        seekTarget = nil
        seekFollowsBottom = false
        seekFollowsTop = false
        pageCoast = false
        clearFingerTracking()
        clearAccel()
    }

    /// Page Up/Down: coast one viewport minus a row. `direction` +1 = older, −1 = toward bottom.
    func applyPageImpulse(direction: Double, viewportRows: Double) {
        if abs(direction) < 1e-9 { return }
        clearFingerTracking()
        resetAccelIfIdleOrChase()
        seekTarget = nil
        seekFollowsBottom = false
        seekFollowsTop = false
        pinnedToBottom = false
        pageCoast = true
        coastFriction = max(friction, 0.05) * 3
        let vp = max(1, viewportRows - 1)
        velocity -= direction * vp * coastFriction
        runTime = max(runTime, 1.5)
    }

    /// Coast to the top (`direction` +1) or bottom (−1). Always reaches the extreme.
    func seekExtreme(
        direction: Double,
        holdCount: Int,
        viewportRows: Double,
        maxOffset: Double
    ) {
        if abs(direction) < 1e-9 { return }
        clearFingerTracking()
        resetAccelIfIdleOrChase()
        seekTarget = nil
        let maxO = max(0, maxOffset)
        pinnedToBottom = false
        pageCoast = false
        seekFollowsTop = direction > 0
        seekFollowsBottom = direction < 0
        _ = holdCount
        _ = viewportRows
        _ = maxO
    }

    /// Jump to top of scrollback.
    func pinTop(maxOffset: Double) {
        _ = maxOffset
        seekTarget = nil
        seekFollowsBottom = false
        seekFollowsTop = false
        pageCoast = false
        clearFingerTracking()
        clearAccel()
        position = 0
        velocity = 0
        pinnedToBottom = false
    }

    /// Jump to bottom and pin.
    func pinBottom(maxOffset: Double) {
        let maxO = max(0, maxOffset)
        seekTarget = nil
        seekFollowsBottom = false
        seekFollowsTop = false
        pageCoast = false
        clearFingerTracking()
        clearAccel()
        position = maxO
        velocity = 0
        pinnedToBottom = true
    }

    /// Ease to an absolute scroll offset (search match, etc.). Wheel / page keys cancel.
    func smoothTo(offset: Double, maxOffset: Double) {
        let maxO = max(0, maxOffset)
        let goal = min(max(offset, 0), maxO)
        clearFingerTracking()
        pinnedToBottom = false
        seekFollowsBottom = false
        seekFollowsTop = false
        pageCoast = false
        let err = goal - position
        if abs(err) < 0.35 {
            seekTarget = nil
            position = goal
            velocity = 0
            pinnedToBottom = abs(goal - maxO) < settlePos
            return
        }
        seekTarget = goal
        // Seed so the first frame moves; step() springs the rest of the way.
        velocity = err * 6
    }

    /// Already coasting toward the live bottom (do not start another kick).
    var isSeekingBottom: Bool { seekFollowsBottom }

    /// True when a keystroke should not start another bottom seek.
    func isAtLiveBottom(maxOffset: Double) -> Bool {
        let maxO = max(0, maxOffset)
        if pinnedToBottom, abs(position - maxO) < 0.35 { return true }
        return abs(position - maxO) < 0.35
    }

    /// Drop the oldest `n` history rows (scrollback cap trim).
    func trimTop(_ n: Double) {
        if n <= 0 { return }
        position = max(0, position - n)
        if let target = seekTarget {
            seekTarget = max(0, target - n)
        }
    }

    /// When pinned, live output sticks to the bottom with no speed cap.
    func followBottomIfPinned(maxOffset: Double) {
        let maxO = max(0, maxOffset)
        guard pinnedToBottom else { return }
        position = maxO
        velocity = 0
    }

    /// Integrate one frame. Returns true if still moving (needs redraw).
    @discardableResult
    func step(dt: Double, maxOffset: Double, viewportRows: Double) -> Bool {
        creditPausedIdle()
        let maxO = max(0, maxOffset)
        let dt = min(max(dt, 0), 0.05)

        if pinnedToBottom {
            seekTarget = nil
            seekFollowsBottom = false
            seekFollowsTop = false
            position = maxO
            velocity = 0
            clearFingerTracking()
            clearAccel()
            return false
        }

        if fingerDown {
            _ = clampToRange(maxO)
            return false
        }

        if seekFollowsTop {
            if position <= settlePos {
                position = 0
                velocity = 0
                seekFollowsTop = false
                clearAccel()
                return false
            }
            velocity = -position / max(dt, 1.0 / 240.0)
        } else if seekFollowsBottom {
            if position >= maxO - settlePos {
                pinBottom(maxOffset: maxO)
                return false
            }
            let remaining = maxO - position
            velocity = remaining / max(dt, 1.0 / 240.0)
        }

        if let target = seekTarget {
            return stepSeek(dt: dt, target: target, maxOffset: maxO, viewportRows: viewportRows)
        }

        let seeking = seekFollowsBottom || seekFollowsTop
        // A coalesced wakeup can tick with dt ≈ 0. Do not treat that as settled.
        if dt <= 0 { return stillMoving() }

        if !seeking, abs(velocity) < settleVel {
            finishCoast(maxO, towardHistory: velocity < 0)
            return false
        }
        let uncapped = seeking ? velocity * dt : coastDisplacement(dt: dt)
        let maxDelta = visualCap()
        let delta = min(max(uncapped, -maxDelta), maxDelta)
        runTime += dt
        position += delta
        if clampToRange(maxO) {
            velocity = 0
            pageCoast = false
            seekFollowsTop = false
            if pinnedToBottom {
                clearAccel()
                return false
            }
        } else if !seeking {
            decayCoast(actualDelta: delta, dt: dt)
            if abs(velocity) < settleVel {
                finishCoast(maxO, towardHistory: velocity < 0)
            }
        }

        if stillMoving() { return true }
        clearAccel()
        return false
    }

    /// Exact ∫ v e^{-μt} dt over this frame (exponential coast, not Euler).
    private func coastDisplacement(dt: Double) -> Double {
        let mu = coastFriction
        if mu <= 1e-12 { return velocity * dt }
        let decay = exp(-mu * dt)
        return velocity * (1 - decay) / mu
    }

    /// Age the exponential by the time that produced `actualDelta`.
    /// A visual cap may shorten this frame's move; it must not shorten the coast.
    private func decayCoast(actualDelta: Double, dt: Double) {
        let mu = coastFriction
        let v = velocity
        if mu <= 1e-12 || abs(v) < 1e-15 {
            velocity = 0
            return
        }
        let remain = 1 - mu * actualDelta / v
        if remain > 0, remain <= 1 {
            velocity = v * remain
        } else {
            velocity = v * exp(-mu * dt)
        }
    }

    private func finishCoast(_ maxO: Double, towardHistory: Bool) {
        if pageCoast {
            position = position.rounded()
            pageCoast = false
        }
        velocity = 0
        clearAccel()
        if position <= 0 {
            position = 0
        } else if position >= maxO - settlePos, !towardHistory {
            pinBottom(maxOffset: maxO)
        }
    }

    private func stillMoving() -> Bool {
        abs(velocity) > settleVel
            || seekFollowsBottom
            || seekFollowsTop
            || seekTarget != nil
    }

    /// Returns true if an edge was hit.
    @discardableResult
    private func clampToRange(_ maxO: Double) -> Bool {
        if position <= 0 {
            position = 0
            return true
        }
        // A short first frame from the prompt must not re-pin a history fling.
        if position >= maxO - settlePos, velocity >= 0 {
            pinBottom(maxOffset: maxO)
            return true
        }
        if position > maxO { position = maxO }
        return false
    }

    /// Rows allowed this frame: 1 at t=0, doubles every `accelHalflife`.
    func visualCap() -> Double {
        let start = max(maxRowsPerFrame, 0.05)
        let t = max(runTime, 0)
        let h = max(accelHalflife, 0.05)
        return start * pow(2.0, t / h)
    }

    private func clearAccel() {
        runTime = 0
    }

    private func clearFingerTracking() {
        fingerDown = false
        lastPreciseAt = 0
    }

    /// Count a paused view as idle even if we were still chasing with leftover velocity.
    private func creditPausedIdle() {
        let t = now()
        defer { lastTickAt = t }
        guard lastTickAt > 0 else { return }
        if t - lastTickAt >= idleReset {
            clearAccel()
        }
    }

    /// Restart the cap for a new gesture (chase, pin, or idle), not a continued fling.
    private func resetAccelIfIdleOrChase() {
        creditPausedIdle()
        if seekFollowsBottom || seekFollowsTop || pinnedToBottom {
            clearAccel()
            velocity = 0
        }
    }

    /// Spring toward `seekTarget` (critically-ish damped).
    private func stepSeek(
        dt: Double,
        target: Double,
        maxOffset: Double,
        viewportRows: Double
    ) -> Bool {
        let maxO = max(0, maxOffset)
        let goal = min(max(target, 0), maxO)
        let err = goal - position

        // Settle when close and slow.
        if abs(err) < 0.2, abs(velocity) < 2 {
            position = goal
            velocity = 0
            seekTarget = nil
            clearAccel()
            if abs(position - maxO) < settlePos {
                pinnedToBottom = true
                position = maxO
            }
            return false
        }

        let k = 110.0
        let c = 20.0
        let a = k * err - c * velocity
        velocity += a * dt
        let maxDelta = visualCap()
        position += min(max(velocity * dt, -maxDelta), maxDelta)
        position = min(max(position, 0), maxO)

        return true
    }

    /// Sync continuous position from terminal scrollbar after external changes.
    func syncFromScrollbar(offset: Double, maxOffset: Double, forcePinIfActive: Bool) {
        let maxO = max(0, maxOffset)
        if forcePinIfActive || pinnedToBottom {
            pinBottom(maxOffset: maxO)
            return
        }
        clearFingerTracking()
        // Don't fight an active seek with hard snaps from scrollbar growth.
        if seekTarget != nil { return }
        position = min(max(offset, 0), maxO)
        velocity = 0
    }
}
