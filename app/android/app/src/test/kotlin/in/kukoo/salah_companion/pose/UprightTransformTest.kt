package `in`.kukoo.salah_companion.pose

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class UprightTransformTest {
    private fun assertPoint(expected: Pair<Float, Float>, actual: Pair<Float, Float>) {
        assertEquals(expected.first, actual.first, 1e-4f)
        assertEquals(expected.second, actual.second, 1e-4f)
    }

    // A typical rear camera: landscape 640x480 buffer, rotationDegrees 90 for a portrait phone.

    @Test
    fun rotation0IsIdentity() {
        val t = UprightTransform(480, 640, 0)
        assertEquals(480, t.uprightW)
        assertEquals(640, t.uprightH)
        assertPoint(10f to 20f, t.toUpright(10f, 20f))
    }

    @Test
    fun rotation90SwapsSizeAndTurnsClockwise() {
        val t = UprightTransform(640, 480, 90)
        assertEquals(480, t.uprightW)
        assertEquals(640, t.uprightH)
        // Buffer top-left goes to upright top-right; buffer bottom-left to upright top-left.
        assertPoint(480f to 0f, t.toUpright(0f, 0f))
        assertPoint(0f to 0f, t.toUpright(0f, 480f))
        assertPoint(480f to 640f, t.toUpright(640f, 0f))
        assertPoint(0f to 640f, t.toUpright(640f, 480f))
        // A head near the buffer's left edge (sensor "up" for a portrait phone is left).
        assertPoint(240f to 10f, t.toUpright(10f, 240f))
    }

    @Test
    fun rotation180FlipsBothAxes() {
        val t = UprightTransform(640, 480, 180)
        assertEquals(640, t.uprightW)
        assertEquals(480, t.uprightH)
        assertPoint(640f to 480f, t.toUpright(0f, 0f))
        assertPoint(630f to 470f, t.toUpright(10f, 10f))
    }

    @Test
    fun rotation270TurnsCounterClockwise() {
        val t = UprightTransform(640, 480, 270)
        assertEquals(480, t.uprightW)
        assertEquals(640, t.uprightH)
        assertPoint(0f to 640f, t.toUpright(0f, 0f))
        assertPoint(0f to 0f, t.toUpright(640f, 0f))
        assertPoint(480f to 0f, t.toUpright(640f, 480f))
    }

    @Test
    fun negativeAndLargeRotationsNormalise() {
        assertEquals(270, UprightTransform(10, 20, -90).rotation)
        assertEquals(90, UprightTransform(10, 20, 450).rotation)
    }

    @Test(expected = IllegalArgumentException::class)
    fun nonRightAngleRotationIsRejected() {
        UprightTransform(10, 20, 45)
    }

    @Test
    fun everyRotationMapsTheBufferOntoTheUprightRectangle() {
        for (r in listOf(0, 90, 180, 270)) {
            val t = UprightTransform(640, 480, r)
            val corners = listOf(0f to 0f, 640f to 0f, 0f to 480f, 640f to 480f).map { t.toUpright(it.first, it.second) }
            assertEquals(
                setOf(0f to 0f, t.uprightW.toFloat() to 0f, 0f to t.uprightH.toFloat(), t.uprightW.toFloat() to t.uprightH.toFloat()),
                corners.toSet(),
            )
        }
    }

    @Test
    fun matrixValuesAreRowMajorAffine() {
        val t = UprightTransform(640, 480, 90)
        assertArrayEquals(floatArrayOf(0f, -1f, 480f, 1f, 0f, 0f, 0f, 0f, 1f), t.matrixValues(), 0f)
    }

    @Test
    fun landmarksScaleToUprightPixelsWithVisibilityAsConf() {
        val out = FloatArray(8)
        UprightTransform.writeLandmark(out, 0, 0.5f, 0.25f, -0.1f, 0.9f, 480, 640)
        UprightTransform.writeLandmark(out, 4, 1f, 1f, 0f, null, 480, 640)
        assertArrayEquals(floatArrayOf(240f, 160f, -48f, 0.9f, 480f, 640f, 0f, 0f), out, 1e-4f)
    }

    @Test
    fun confIsClampedToUnitRange() {
        val out = FloatArray(4)
        UprightTransform.writeLandmark(out, 0, 0f, 0f, 0f, 1.2f, 1, 1)
        assertEquals(1f, out[3], 0f)
    }
}
