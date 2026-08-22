import Foundation

/// Continuous scroll position + DOS-demo-style spring overscroll.
///
/// Units: **rows** (viewport-relative). `position == 0` is the top of scrollback;
/// `position == maxOffset` is pinned to the active bottom. Overshoot beyond
/// [0, maxOffset] is allowed and pulled back with a spring.
public final class ScrollPhysics {
    /// Continuous offset into the scrollable range (rows from top of history).
    private(set) var position: Double = 0
    /// Rows per second.
    private(set) var velocity: Double = 0
    /// When true, stick to the bottom as new output arrives.
    private(set) var pinnedToBottom: Bool = true

    var springK: Double = 120
    var springC: Double = 14
    var friction: Double = 6
    /// Max overscroll as a fraction of the visible viewport height (rows).
    var maxOverscrollFraction: Double = 0.35
    /// Wheel/trackpad → velocity scale.
    var impulseScale: Double = 18
    /// Starting visual cap (rows/frame). Grows with `runTime` until unrestricted.
    var maxRowsPerFrame: Double = 1.0
    /// Seconds for the cap to double. ~1.4s to pass 64 rows/frame.
    var accelHalflife: Double = 0.2

    private let settlePos: Double = 0.02
    private let settleVel: Double = 0.15
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

    /// Integer row for `GHOSTTY_SCROLL_VIEWPORT_ROW` (clamped into range).
    func integerRow(maxOffset: Double) -> UInt64 {
        let maxO = max(0, maxOffset)
        if position <= 0 { return 0 }
        if position >= maxO { return UInt64(maxO.rounded(.down)) }
        return UInt64(position.rounded(.down))
    }

    /// Fractional part in [0, 1) while in range; overscroll encoded as offset outside.
    /// Pixel shift applied as `y += visualOffsetRows * cellHeight` (top-left coords).
    func visualOffsetRows(maxOffset: Double) -> Double {
        let maxO = max(0, maxOffset)
        if position < 0 {
            // Pull content downward (reveal empty above).
            return -position
        }
        if position > maxO {
            // Pull content upward past the bottom.
            return -(position - maxO)
        }
        let frac = position - floor(position)
        // Shift content up so the next row peeks in from the bottom.
        return -frac
    }

    /// Apply a wheel/trackpad impulse.
    /// Positive `deltaRows` moves toward older history (position decreases toward 0).
    func applyImpulse(deltaRows: Double) {
        if abs(deltaRows) < 1e-9 { return }
        resetAccelIfIdleOrChase()
        seekTarget = nil
        seekFollowsBottom = false
        seekFollowsTop = false
        pinnedToBottom = false
        // +impulse → older history → lower position → negative velocity.
        velocity -= deltaRows * impulseScale
    }

    /// Smooth page-key fling. `direction` +1 = older (Page Up), −1 = toward bottom.
    /// `holdCount` starts at 1 on first press and grows with key-repeat for acceleration.
    func applyPageImpulse(direction: Double, holdCount: Int, viewportRows: Double) {
        if abs(direction) < 1e-9 { return }
        resetAccelIfIdleOrChase()
        seekTarget = nil
        seekFollowsBottom = false
        seekFollowsTop = false
        let vp = max(1, viewportRows)
        pinnedToBottom = false
        // Initial kick ~ coasts about a page; repeats multiply (capped).
        let base = vp * 5.5
        let mult = min(1.0 + Double(max(0, holdCount - 1)) * 0.45, 7.0)
        let kick = base * mult
        velocity -= direction * kick
    }

    /// Coast to the top (`direction` +1) or bottom (−1), then overscroll-bounce
    /// like page / wheel. Always reaches the extreme; repeats accelerate.
    func seekExtreme(
        direction: Double,
        holdCount: Int,
        viewportRows: Double,
        maxOffset: Double
    ) {
        if abs(direction) < 1e-9 { return }
        resetAccelIfIdleOrChase()
        seekTarget = nil
        let maxO = max(0, maxOffset)
        pinnedToBottom = false
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
        clearAccel()
        position = maxO
        velocity = 0
        pinnedToBottom = true
    }

    /// Ease to an absolute scroll offset (search match, etc.). Wheel / page keys cancel.
    func smoothTo(offset: Double, maxOffset: Double) {
        let maxO = max(0, maxOffset)
        let goal = min(max(offset, 0), maxO)
        pinnedToBottom = false
        seekFollowsBottom = false
        seekFollowsTop = false
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

    /// True when a keystroke should not start another bottom seek / bounce.
    func isAtLiveBottom(maxOffset: Double) -> Bool {
        let maxO = max(0, maxOffset)
        if position > maxO { return true }
        if pinnedToBottom, abs(position - maxO) < 0.35 { return true }
        return false
    }

    /// Drop the oldest `n` history rows (scrollback cap trim).
    func trimTop(_ n: Double) {
        if n <= 0 { return }
        position = max(0, position - n)
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
        let maxOver = max(0.5, viewportRows * maxOverscrollFraction)
        let dt = min(max(dt, 0), 0.05)

        if pinnedToBottom {
            seekTarget = nil
            seekFollowsBottom = false
            seekFollowsTop = false
            position = maxO
            velocity = 0
            clearAccel()
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

        // Programmatic ease (search match). Extremes use free physics + bounce.
        if let target = seekTarget {
            return stepSeek(dt: dt, target: target, maxOffset: maxO, viewportRows: viewportRows)
        }

        let maxDelta = visualCap()
        let seeking = seekFollowsBottom || seekFollowsTop
        let delta = min(max(velocity * dt, -maxDelta), maxDelta)
        if !seeking, abs(delta) < 0.02 {
            velocity = 0
            clearAccel()
            if position < 0 {
                position = 0
            } else if position > maxO - settlePos {
                pinnedToBottom = true
                position = maxO
            }
            return false
        }
        runTime += dt
        position += delta

        // Soft clamp overscroll
        if position < -maxOver {
            position = -maxOver
            velocity = max(0, velocity)
        } else if position > maxO + maxOver {
            position = maxO + maxOver
            velocity = min(0, velocity)
        }

        // Forces
        if position < 0 {
            applyOverscrollSpring(offset: position, dt: dt)
        } else if position > maxO {
            applyOverscrollSpring(offset: position - maxO, dt: dt)
        } else {
            // Friction / coast inside the range
            velocity *= exp(-friction * dt)
            if abs(velocity) < settleVel {
                velocity = 0
            }
        }

        // Settle overscroll
        if position < 0 || position > maxO {
            if abs(velocity) < settleVel, abs(position < 0 ? position : position - maxO) < settlePos {
                position = min(max(position, 0), maxO)
                velocity = 0
                if abs(position - maxO) < settlePos {
                    pinnedToBottom = true
                    position = maxO
                }
            }
        } else if abs(velocity) < settleVel {
            velocity = 0
        }

        let moving = abs(velocity) > settleVel
            || position < -settlePos
            || position > maxO + settlePos
            || seekFollowsBottom
            || seekFollowsTop
        if moving { return true }
        clearAccel()
        return false
    }

    /// Overdamped rubber band. `springC` is a floor so config can damp more, not less.
    private func applyOverscrollSpring(offset: Double, dt: Double) {
        let c = max(springC, 2.4 * sqrt(springK))
        velocity += (-springK * offset - c * velocity) * dt
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

        // Stiffer than overscroll spring so long jumps finish in ~0.25–0.4s.
        let k = 110.0
        let c = 20.0
        let a = k * err - c * velocity
        velocity += a * dt
        let maxDelta = visualCap()
        position += min(max(velocity * dt, -maxDelta), maxDelta)
        position = min(max(position, -0.5), maxO + 0.5)

        return true
    }

    /// Sync continuous position from terminal scrollbar after external changes.
    func syncFromScrollbar(offset: Double, maxOffset: Double, forcePinIfActive: Bool) {
        let maxO = max(0, maxOffset)
        if forcePinIfActive || pinnedToBottom {
            pinBottom(maxOffset: maxO)
            return
        }
        // Don't fight an active seek with hard snaps from scrollbar growth.
        if seekTarget != nil { return }
        position = min(max(offset, 0), maxO)
        velocity = 0
    }
}
