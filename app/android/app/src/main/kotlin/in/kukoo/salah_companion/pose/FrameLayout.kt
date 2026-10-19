package `in`.kukoo.salah_companion.pose

/**
 * Memory layout of one RGBA_8888 ImageAnalysis plane, to copy it into a reused bitmap
 * (`Bitmap.copyPixelsFromBuffer` needs tightly packed rows). Pure Kotlin, JVM-tested.
 *
 * - [packed]: rows have no padding and the buffer holds the whole image, so it can be copied
 *   in one call.
 * - Otherwise each row of [rowBytes] starts at a multiple of [rowStride]; the last row may be
 *   cut short after its pixels (common on real devices), which is why the buffer only has to
 *   hold `rowStride * (height - 1) + rowBytes` bytes.
 */
data class FrameLayout(val rowBytes: Int, val rowStride: Int, val packed: Boolean) {
    fun packedBytes(height: Int): Int = rowBytes * height

    companion object {
        const val BYTES_PER_PIXEL = 4

        /** The layout, or null if the plane is not plain RGBA_8888 this code can copy. */
        fun of(width: Int, height: Int, rowStride: Int, pixelStride: Int, capacity: Int): FrameLayout? {
            if (width <= 0 || height <= 0 || pixelStride != BYTES_PER_PIXEL) return null
            val rowBytes = width * BYTES_PER_PIXEL
            if (rowStride < rowBytes) return null
            val needed = rowStride.toLong() * (height - 1) + rowBytes
            if (capacity < needed) return null
            val packed = rowStride == rowBytes && capacity >= rowBytes.toLong() * height
            return FrameLayout(rowBytes, rowStride, packed)
        }
    }
}
