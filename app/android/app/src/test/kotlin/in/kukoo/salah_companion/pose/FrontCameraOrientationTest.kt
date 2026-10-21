package `in`.kukoo.salah_companion.pose

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Front-camera orientation: the analysis buffer of a front camera is the raw, unmirrored
 * sensor readout, mounted at SENSOR_ORIENTATION (commonly 270, some phones 90). Rotating it
 * clockwise by CameraX's rotationDegrees must give the upright, UNMIRRORED frame, exactly as
 * for the rear camera, so the landmarks Dart receives have real-world geometry for both lenses.
 */
class FrontCameraOrientationTest {
    // ---- CameraOrientation.analysisRotation (mirrors CameraX) ---------------------------

    @Test
    fun portraitPhoneUsesTheSensorOrientationForBothLenses() {
        // The analysis use case always targets ROTATION_0 (phone upright in portrait).
        assertEquals(90, CameraOrientation.analysisRotation(90, front = false, targetRotationDeg = 0))
        assertEquals(270, CameraOrientation.analysisRotation(270, front = true, targetRotationDeg = 0))
        assertEquals(90, CameraOrientation.analysisRotation(90, front = true, targetRotationDeg = 0))
        assertEquals(270, CameraOrientation.analysisRotation(270, front = false, targetRotationDeg = 0))
    }

    @Test
    fun landscapeTargetsTurnFrontAndBackOppositeWays() {
        // Display rotated 90 (landscape, phone turned counter-clockwise).
        assertEquals(0, CameraOrientation.analysisRotation(90, front = false, targetRotationDeg = 90))
        assertEquals(0, CameraOrientation.analysisRotation(270, front = true, targetRotationDeg = 90))
        assertEquals(180, CameraOrientation.analysisRotation(90, front = true, targetRotationDeg = 90))
        // Display rotated 270 (landscape the other way).
        assertEquals(180, CameraOrientation.analysisRotation(90, front = false, targetRotationDeg = 270))
        assertEquals(180, CameraOrientation.analysisRotation(270, front = true, targetRotationDeg = 270))
        assertEquals(0, CameraOrientation.analysisRotation(90, front = true, targetRotationDeg = 270))
        // Upside-down portrait.
        assertEquals(90, CameraOrientation.analysisRotation(270, front = true, targetRotationDeg = 180))
        assertEquals(270, CameraOrientation.analysisRotation(90, front = false, targetRotationDeg = 180))
    }

    @Test
    fun surfaceRotationConstantsMapToDegrees() {
        assertEquals(listOf(0, 90, 180, 270), (0..3).map { CameraOrientation.surfaceRotationDegrees(it) })
    }

    // ---- A synthetic scene through a front sensor ----------------------------------------

    /**
     * What a sensor mounted at [sensorOrientation] reads out for an upright scene of
     * [w] x [h]: the scene turned counter-clockwise by that angle (SENSOR_ORIENTATION is the
     * clockwise angle that makes the readout upright). Built in independent 90-degree steps.
     * No mirroring: a front sensor's buffer is not mirrored.
     */
    private fun sensorPoint(x: Float, y: Float, w: Int, h: Int, sensorOrientation: Int): Triple<Float, Float, Pair<Int, Int>> {
        var px = x
        var py = y
        var cw = w
        var ch = h
        repeat(((sensorOrientation % 360) + 360) % 360 / 90) {
            // One quarter turn counter-clockwise: (x, y) in W x H -> (y, W - x) in H x W.
            val nx = py
            val ny = cw - px
            px = nx
            py = ny
            val t = cw
            cw = ch
            ch = t
        }
        return Triple(px, py, cw to ch)
    }

    /** Upright, unmirrored scene (480 x 640 portrait): a user facing the phone. */
    private val scene = mapOf(
        "head" to (240f to 60f),
        "usersRightHand" to (90f to 330f), // appears on the image's LEFT (unmirrored)
        "usersLeftHand" to (390f to 330f),
        "feet" to (240f to 620f),
    )

    private fun assertRoundTrip(sensorOrientation: Int, front: Boolean) {
        val rotation = CameraOrientation.analysisRotation(sensorOrientation, front, 0)
        val (_, _, size) = sensorPoint(0f, 0f, 480, 640, sensorOrientation)
        val xf = UprightTransform(size.first, size.second, rotation)
        assertEquals(480, xf.uprightW)
        assertEquals(640, xf.uprightH)
        for ((name, p) in scene) {
            val (bx, by, _) = sensorPoint(p.first, p.second, 480, 640, sensorOrientation)
            val (ux, uy) = xf.toUpright(bx, by)
            assertEquals("$name x (sensor $sensorOrientation, front $front)", p.first, ux, 1e-3f)
            assertEquals("$name y (sensor $sensorOrientation, front $front)", p.second, uy, 1e-3f)
        }
        // The user's right hand stays on the image's left: no mirroring crept in.
        val right = xf.toUpright(
            sensorPoint(90f, 330f, 480, 640, sensorOrientation).first,
            sensorPoint(90f, 330f, 480, 640, sensorOrientation).second,
        )
        val left = xf.toUpright(
            sensorPoint(390f, 330f, 480, 640, sensorOrientation).first,
            sensorPoint(390f, 330f, 480, 640, sensorOrientation).second,
        )
        assertTrue(right.first < left.first)
    }

    @Test
    fun frontSensorAt270GivesTheUprightUnmirroredFrame() = assertRoundTrip(270, front = true)

    @Test
    fun frontSensorAt90GivesTheUprightUnmirroredFrame() = assertRoundTrip(90, front = true)

    @Test
    fun rearSensorAt90StillWorks() = assertRoundTrip(90, front = false)

    @Test
    fun front270BufferIsLandscapeAndHeadStartsAtTheBufferRightEdge() {
        // 270: the scene's top edge is read out along the buffer's right edge.
        val (bx, by, size) = sensorPoint(240f, 0f, 480, 640, 270)
        assertEquals(640 to 480, size)
        assertEquals(640f, bx, 1e-3f)
        assertEquals(240f, by, 1e-3f)
        assertEquals(240f to 0f, UprightTransform(640, 480, 270).toUpright(bx, by))
    }

    @Test
    fun pixelGridThroughTheBitmapMatrixMatchesTheScene() {
        // A tiny 3 x 2 upright image of distinct pixels, read out by a front sensor at 270 and
        // at 90, then drawn upright with the same matrix the analyzer gives Canvas.drawBitmap.
        val w = 3
        val h = 2
        val upright = IntArray(w * h) { it + 1 }
        for (orientation in listOf(90, 270)) {
            val (_, _, size) = sensorPoint(0f, 0f, w, h, orientation)
            val (bw, bh) = size
            val buffer = IntArray(bw * bh)
            for (y in 0 until h) for (x in 0 until w) {
                val (bx, by, _) = sensorPoint(x + 0.5f, y + 0.5f, w, h, orientation)
                buffer[(by - 0.5f).toInt() * bw + (bx - 0.5f).toInt()] = upright[y * w + x]
            }
            val xf = UprightTransform(bw, bh, CameraOrientation.analysisRotation(orientation, true, 0))
            val m = xf.matrixValues()
            val out = IntArray(xf.uprightW * xf.uprightH)
            for (y in 0 until bh) for (x in 0 until bw) {
                val cx = x + 0.5f
                val cy = y + 0.5f
                val ux = m[0] * cx + m[1] * cy + m[2]
                val uy = m[3] * cx + m[4] * cy + m[5]
                out[(uy - 0.5f).toInt() * xf.uprightW + (ux - 0.5f).toInt()] = buffer[y * bw + x]
            }
            assertArrayEquals("sensor $orientation", upright, out)
        }
    }

    @Test
    fun everyRotationIsAProperRotationNeverAReflection() {
        for (r in listOf(0, 90, 180, 270)) {
            val a = UprightTransform(640, 480, r).affine
            val det = a[0] * a[4] - a[1] * a[3]
            assertEquals("rotation $r", 1f, det, 0f)
        }
    }

    // ---- LensChoice ----------------------------------------------------------------------

    @Test
    fun requestedLensIsUsedWhenPresent() {
        assertEquals(LensChoice(true, "front", false), LensChoice.resolve("front", hasFront = true, hasBack = true))
        assertEquals(LensChoice(false, "rear", false), LensChoice.resolve("rear", hasFront = true, hasBack = true))
        assertEquals(
            LensChoice(false, "rearUltraWide", false),
            LensChoice.resolve("rearUltraWide", hasFront = true, hasBack = true),
        )
        assertEquals("front", LensChoice.resolve("front", true, true)!!.label)
        assertEquals("rear", LensChoice.resolve("rear", true, true)!!.label)
    }

    @Test
    fun missingLensFallsBackToTheOtherAndSaysSo() {
        val noFront = LensChoice.resolve("front", hasFront = false, hasBack = true)!!
        assertFalse(noFront.front)
        assertTrue(noFront.fellBack)
        assertEquals("rear", noFront.label)
        val noBack = LensChoice.resolve("rear", hasFront = true, hasBack = false)!!
        assertTrue(noBack.front)
        assertTrue(noBack.fellBack)
        assertEquals("front", noBack.label)
        assertNull(LensChoice.resolve("front", hasFront = false, hasBack = false))
    }

    @Test
    fun unknownLensNamesMeanRear() {
        assertEquals(LensChoice(false, "selfie", false), LensChoice.resolve("selfie", true, true))
    }
}
