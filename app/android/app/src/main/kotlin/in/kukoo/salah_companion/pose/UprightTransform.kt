package `in`.kukoo.salah_companion.pose

/**
 * Maps the camera buffer to the upright frame the Dart side expects (docs/SPEC.md section 5:
 * "x, y in pixels of the upright (rotated, unmirrored) frame").
 *
 * CameraX reports `rotationDegrees`: the clockwise rotation that makes the buffer upright
 * for the requested target rotation (see [CameraOrientation.analysisRotation]): usually 90
 * for a rear camera and 270 for a front camera on a portrait phone. ImageAnalysis buffers are
 * the raw sensor readout and are never mirrored, for either lens, so this rotation alone gives
 * the upright, unmirrored frame. We never mirror front-camera frames here: only the on-screen
 * preview is mirrored (PreviewView), and Dart mirrors the skeleton overlay to match it.
 *
 * The analyzer draws the buffer into an upright bitmap with [matrixValues] (so MediaPipe sees
 * people upright, which its detector needs), then MediaPipe's normalised landmarks are scaled
 * to pixels with [normalizedToPixels]. Pure Kotlin so it can be unit-tested on the JVM.
 */
class UprightTransform(val bufferW: Int, val bufferH: Int, rotationDegrees: Int) {
    /** Clockwise rotation, normalised to 0, 90, 180 or 270. */
    val rotation: Int

    val uprightW: Int
    val uprightH: Int

    /**
     * Affine map buffer -> upright as `[a, b, c, d, e, f]`:
     * `x' = a*x + b*y + c`, `y' = d*x + e*y + f` (continuous pixel coordinates, so the buffer
     * corner (0, 0) maps exactly onto an upright corner).
     */
    val affine: FloatArray

    init {
        require(bufferW > 0 && bufferH > 0) { "bad buffer size ${bufferW}x$bufferH" }
        require(rotationDegrees % 90 == 0) { "rotation must be a multiple of 90, was $rotationDegrees" }
        rotation = ((rotationDegrees % 360) + 360) % 360
        val swap = rotation == 90 || rotation == 270
        uprightW = if (swap) bufferH else bufferW
        uprightH = if (swap) bufferW else bufferH
        val w = bufferW.toFloat()
        val h = bufferH.toFloat()
        affine = when (rotation) {
            0 -> floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f)
            // Rotate 90 deg clockwise: the buffer's left edge becomes the top edge.
            90 -> floatArrayOf(0f, -1f, h, 1f, 0f, 0f)
            180 -> floatArrayOf(-1f, 0f, w, 0f, -1f, h)
            else -> floatArrayOf(0f, 1f, 0f, -1f, 0f, w) // 270
        }
    }

    /** Maps a buffer point to the upright frame. */
    fun toUpright(x: Float, y: Float): Pair<Float, Float> {
        val m = affine
        return Pair(m[0] * x + m[1] * y + m[2], m[3] * x + m[4] * y + m[5])
    }

    /** Values for `android.graphics.Matrix.setValues` (row-major 3x3). */
    fun matrixValues(): FloatArray =
        floatArrayOf(affine[0], affine[1], affine[2], affine[3], affine[4], affine[5], 0f, 0f, 1f)

    companion object {
        /**
         * Scales one MediaPipe landmark, normalised to the upright image it was given, to
         * pixels. z uses the x scale (MediaPipe: "z uses roughly the same scale as x").
         * Writes (x, y, z, conf) into [out] at [offset].
         */
        fun writeLandmark(
            out: FloatArray,
            offset: Int,
            nx: Float,
            ny: Float,
            nz: Float,
            visibility: Float?,
            imageW: Int,
            imageH: Int,
        ) {
            out[offset] = nx * imageW
            out[offset + 1] = ny * imageH
            out[offset + 2] = nz * imageW
            out[offset + 3] = (visibility ?: 0f).coerceIn(0f, 1f)
        }

        fun normalizedToPixels(nx: Float, ny: Float, imageW: Int, imageH: Int): Pair<Float, Float> =
            Pair(nx * imageW, ny * imageH)
    }
}
