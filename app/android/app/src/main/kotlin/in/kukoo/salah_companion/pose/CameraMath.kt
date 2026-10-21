package `in`.kukoo.salah_companion.pose

import kotlin.math.atan
import kotlin.math.atan2
import kotlin.math.hypot

/**
 * Caps analysis at the target rate using sensor timestamps (docs/SPEC.md: analysis fixed at
 * 15 fps on every phone). Long-run rate never exceeds [fps]; a camera already at [fps] with
 * jitter keeps every frame; after a stall it does not burst.
 */
class FramePacer(fps: Int) {
    private val intervalNs = 1_000_000_000L / fps
    private val toleranceNs = intervalNs / 4
    private var nextDueNs = Long.MIN_VALUE

    init {
        require(fps > 0)
    }

    fun accept(timestampNs: Long): Boolean {
        if (nextDueNs != Long.MIN_VALUE && timestampNs < nextDueNs - toleranceNs) return false
        val base = if (nextDueNs == Long.MIN_VALUE) timestampNs else maxOf(nextDueNs, timestampNs - toleranceNs)
        nextDueNs = base + intervalNs
        return true
    }

    fun reset() {
        nextDueNs = Long.MIN_VALUE
    }
}

/**
 * Phone roll from the accelerometer, relative to a reference taken at session start.
 *
 * Roll is the rotation about the axis through the screen (the camera axis): 0 when the phone
 * stands upright in portrait, positive when it turns counter-clockwise as seen from the screen.
 * A low-pass filter isolates gravity. When the phone lies nearly flat, roll is undefined and
 * the last value is kept.
 */
class TiltTracker(private val alpha: Float = 0.15f) {
    private var gx = 0f
    private var gy = 0f
    private var gz = 0f
    private var hasSample = false
    private var roll = 0f
    private var reference: Float? = null
    private var wantReference = false

    fun update(ax: Float, ay: Float, az: Float) {
        if (!hasSample) {
            gx = ax; gy = ay; gz = az
            hasSample = true
        } else {
            gx += alpha * (ax - gx)
            gy += alpha * (ay - gy)
            gz += alpha * (az - gz)
        }
        if (hypot(gx, gy) >= MIN_IN_PLANE) {
            roll = Math.toDegrees(atan2(gx.toDouble(), gy.toDouble())).toFloat()
        }
        if (wantReference) {
            reference = roll
            wantReference = false
        }
    }

    /** Current absolute roll in degrees. */
    fun rollDeg(): Float = roll

    /** Takes the current roll as the session reference (or the first sample, if none yet). */
    fun markReference() {
        if (hasSample) reference = roll else wantReference = true
    }

    /** Roll relative to the reference, wrapped into (-180, 180]; 0 before any reference. */
    fun relativeDeg(): Float {
        val ref = reference ?: return 0f
        return wrap(roll - ref)
    }

    companion object {
        /** m/s^2: below this, gravity is nearly along the camera axis (phone flat). */
        const val MIN_IN_PLANE = 2.0f

        fun wrap(deg: Float): Float {
            var d = deg % 360f
            if (d <= -180f) d += 360f
            if (d > 180f) d -= 360f
            return d
        }
    }
}

/** Chooses the camera's AE target FPS range. */
object FpsRangePicker {
    /**
     * Prefers a range that holds the frame rate at or above [target] (lower bound closest to
     * [target]), then the smallest upper bound: [15,15] > [15,30] > [10,15] > [7,30].
     * Returns null when no range contains [target].
     */
    fun pick(ranges: List<Pair<Int, Int>>, target: Int): Pair<Int, Int>? =
        ranges
            .filter { (lo, hi) -> lo <= target && target <= hi }
            .sortedWith(compareByDescending<Pair<Int, Int>> { it.first }.thenBy { it.second })
            .firstOrNull()
}

/** One back camera as seen through Camera2 characteristics. */
data class LensInfo(val id: String, val minFocalLengthMm: Float, val sensorWidthMm: Float) {
    /** Horizontal field of view of the sensor's long side, in degrees. */
    val fovDeg: Double
        get() = Math.toDegrees(2 * atan(sensorWidthMm / (2.0 * minFocalLengthMm)))
}

object LensPicker {
    /** The widest lens (largest field of view), or null if none has usable numbers. */
    fun widest(lenses: List<LensInfo>): LensInfo? =
        lenses.filter { it.minFocalLengthMm > 0f && it.sensorWidthMm > 0f }.maxByOrNull { it.fovDeg }
}

/**
 * Which camera to open for a requested lens (Dart's `CameraLens.name`: rear, rearUltraWide,
 * front). If the phone has no camera facing the requested way, the other one is used and
 * [fellBack] is set; the `started` event then reports the lens actually active, so Dart can
 * mirror the overlay (front only) and the placement screen can show the right state.
 */
data class LensChoice(val front: Boolean, val requested: String, val fellBack: Boolean) {
    /** Base label of the active lens: "front" or "rear" (ultra-wide is refined later). */
    val label: String get() = if (front) LENS_FRONT else LENS_REAR

    companion object {
        const val LENS_FRONT = "front"
        const val LENS_REAR = "rear"
        const val LENS_REAR_ULTRA_WIDE = "rearUltraWide"

        /** Null when the phone has no camera at all. Unknown names read as rear. */
        fun resolve(requested: String, hasFront: Boolean, hasBack: Boolean): LensChoice? {
            val wantFront = requested == LENS_FRONT
            return when {
                wantFront && hasFront -> LensChoice(true, requested, false)
                !wantFront && hasBack -> LensChoice(false, requested, false)
                wantFront && hasBack -> LensChoice(false, requested, true)
                !wantFront && hasFront -> LensChoice(true, requested, true)
                else -> null
            }
        }
    }
}

/**
 * Camera orientation math, matching what CameraX reports as `ImageInfo.rotationDegrees`
 * (Camera2 `SENSOR_ORIENTATION` combined with the use case's target rotation).
 *
 * The ImageAnalysis buffer is the raw sensor readout for BOTH lenses: it is never mirrored,
 * not even for the front camera (only the preview is mirrored, for display). Rotating it
 * clockwise by [analysisRotation] therefore gives the upright, unmirrored picture: what a
 * camera at the phone's position sees, with the user's right side on the image's left when
 * they face the phone. Front sensors are usually mounted at 270 degrees, rear ones at 90.
 */
object CameraOrientation {
    /** Degrees for a `Surface.ROTATION_*` constant (0..3). */
    fun surfaceRotationDegrees(surfaceRotation: Int): Int = when (surfaceRotation) {
        1 -> 90
        2 -> 180
        3 -> 270
        else -> 0
    }

    /**
     * Clockwise rotation that makes an analysis buffer upright for a UI at
     * [targetRotationDeg] (0 = phone upright in portrait; the analysis always uses 0).
     * A back camera turns the opposite way to the display, a front camera the same way
     * (CameraX `CameraOrientationUtil.getRelativeImageRotation`).
     */
    fun analysisRotation(sensorOrientation: Int, front: Boolean, targetRotationDeg: Int): Int {
        require(sensorOrientation % 90 == 0 && targetRotationDeg % 90 == 0)
        val s = ((sensorOrientation % 360) + 360) % 360
        val t = ((targetRotationDeg % 360) + 360) % 360
        return if (front) (s + t) % 360 else (s - t + 360) % 360
    }
}
