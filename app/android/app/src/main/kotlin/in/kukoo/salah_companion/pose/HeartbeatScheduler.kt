package `in`.kukoo.salah_companion.pose

/**
 * Heartbeat rule from docs/SPEC.md section 5, as a pure state machine (JVM-testable):
 *
 * - A heartbeat is emitted only after [periodMs] with no camera frame, stamped
 *   `lastFrameT + k * periodMs` on the sensor clock (k = 1, 2, ...) for as long as no
 *   frame arrives.
 * - Every camera frame (with or without a person) resets the heartbeat clock.
 * - Heartbeats are never interleaved with frames: the output is strictly increasing in tMs.
 *
 * Timing: frames carry sensor timestamps (tMs) but are delivered later, after inference.
 * "No camera frame for 100 ms" is measured on the delivery clock ([onFrame]'s `arrivalMs`,
 * e.g. SystemClock.elapsedRealtime), and heartbeat k becomes due at
 * `arrival + k * periodMs + guardMs`. The guard absorbs jitter in pipeline latency so a frame
 * captured before a heartbeat's stamp is (almost always) delivered before that heartbeat.
 * If one still arrives late, i.e. with tMs <= the last emitted stamp, [onFrame] returns false
 * and the caller drops it, so the emitted stream always obeys the rule (and replays
 * identically through the replay harness).
 *
 * Before the first frame there is no sensor clock, so no heartbeats.
 */
class HeartbeatScheduler(
    val periodMs: Long = 100,
    val guardMs: Long = 50,
) {
    private var lastFrameT = NONE
    private var lastArrival = 0L
    private var k = 0L
    private var lastStamp = NONE

    var droppedLateFrames = 0
        private set

    /** Whether a frame has been seen. */
    val started: Boolean get() = lastFrameT != NONE

    /**
     * Records a camera frame. Returns false if the frame must be dropped because a heartbeat
     * (or frame) at or after its timestamp was already emitted.
     */
    fun onFrame(tMs: Long, arrivalMs: Long): Boolean {
        if (lastStamp != NONE && tMs <= lastStamp) {
            droppedLateFrames++
            return false
        }
        lastFrameT = tMs
        lastArrival = arrivalMs
        k = 0
        lastStamp = tMs
        return true
    }

    /** Delivery-clock time at which the next heartbeat is due, or null before the first frame. */
    fun nextDueAt(): Long? =
        if (lastFrameT == NONE) null else lastArrival + (k + 1) * periodMs + guardMs

    /** Returns the stamps (tMs) of every heartbeat due at delivery time [nowMs], in order. */
    fun poll(nowMs: Long): List<Long> {
        if (lastFrameT == NONE) return emptyList()
        var out: MutableList<Long>? = null
        while (nowMs >= lastArrival + (k + 1) * periodMs + guardMs) {
            k++
            val stamp = lastFrameT + k * periodMs
            lastStamp = stamp
            (out ?: mutableListOf<Long>().also { out = it }).add(stamp)
        }
        return out ?: emptyList()
    }

    fun reset() {
        lastFrameT = NONE
        lastStamp = NONE
        lastArrival = 0
        k = 0
        droppedLateFrames = 0
    }

    private companion object {
        const val NONE = Long.MIN_VALUE
    }
}
