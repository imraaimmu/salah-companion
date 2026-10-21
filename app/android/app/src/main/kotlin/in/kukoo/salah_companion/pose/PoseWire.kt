package `in`.kukoo.salah_companion.pose

/**
 * Wire format for pose events sent to Dart over the EventChannel. Pure Kotlin (no Android
 * types) so it can be unit-tested on the JVM. The Dart decoder is
 * `app/lib/src/pose/pose_wire.dart`; both sides are tested against the same golden vector.
 *
 * Frames and heartbeats are sent as one `FloatArray` (Float32List in Dart, no JSON):
 *
 * | index | meaning                                                                 |
 * | ----- | ----------------------------------------------------------------------- |
 * | 0     | format/kind: [KIND_FRAME] or [KIND_HEARTBEAT]                           |
 * | 1     | session token chosen by Dart in `start` (echoed so stale events drop)   |
 * | 2     | tMs div 65536 (tMs = sensor timestamp - session start, in ms)           |
 * | 3     | tMs mod 65536 (split so every value is exact in float32)                |
 * | 4     | imageW (upright frame, pixels)                                          |
 * | 5     | imageH                                                                  |
 * | 6     | tiltDeg (phone roll relative to session start; 0 for heartbeats)       |
 * | 7     | N = number of people (0..[MAX_PEOPLE]; always 0 for heartbeats)         |
 * | 8..   | N x 33 landmarks x (x, y, z, conf)                                      |
 *
 * x, y are pixels of the upright, unmirrored frame; z is MediaPipe's z scaled by imageW
 * (MediaPipe documents z on roughly the same scale as x, origin at the hip midpoint);
 * conf is MediaPipe's per-landmark `visibility` (0 when absent).
 *
 * Errors and session info are sent as maps, not float arrays (see PoseSession).
 */
object PoseWire {
    const val KIND_FRAME = 0f
    const val KIND_HEARTBEAT = 1f
    const val HEADER = 8
    const val LANDMARKS = 33
    const val FIELDS = 4
    const val PERSON_FLOATS = LANDMARKS * FIELDS
    const val MAX_PEOPLE = 3

    private const val SPLIT = 65536L

    fun frame(
        token: Int,
        tMs: Long,
        imageW: Int,
        imageH: Int,
        tiltDeg: Float,
        people: List<FloatArray>,
    ): FloatArray {
        val n = minOf(people.size, MAX_PEOPLE)
        val out = FloatArray(HEADER + n * PERSON_FLOATS)
        header(out, KIND_FRAME, token, tMs, imageW, imageH, tiltDeg, n)
        for (i in 0 until n) {
            val p = people[i]
            require(p.size == PERSON_FLOATS) { "person $i has ${p.size} floats, want $PERSON_FLOATS" }
            p.copyInto(out, HEADER + i * PERSON_FLOATS)
        }
        return out
    }

    fun heartbeat(token: Int, tMs: Long, imageW: Int, imageH: Int): FloatArray {
        val out = FloatArray(HEADER)
        header(out, KIND_HEARTBEAT, token, tMs, imageW, imageH, 0f, 0)
        return out
    }

    /** Reads tMs back (used by tests and debugging). */
    fun tMs(data: FloatArray): Long = data[2].toLong() * SPLIT + data[3].toLong()

    private fun header(
        out: FloatArray,
        kind: Float,
        token: Int,
        tMs: Long,
        w: Int,
        h: Int,
        tilt: Float,
        n: Int,
    ) {
        require(tMs >= 0) { "tMs must be >= 0, was $tMs" }
        require(token in 0..MAX_EXACT) { "token out of float32-exact range: $token" }
        out[0] = kind
        out[1] = token.toFloat()
        out[2] = (tMs / SPLIT).toFloat()
        out[3] = (tMs % SPLIT).toFloat()
        out[4] = w.toFloat()
        out[5] = h.toFloat()
        out[6] = tilt
        out[7] = n.toFloat()
    }

    private const val MAX_EXACT = 1 shl 24
}
