package `in`.kukoo.salah_companion.pose

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.cos
import kotlin.math.sin

class CameraMathTest {
    private val ms = 1_000_000L

    @Test
    fun pacerHalves30fpsTo15() {
        val p = FramePacer(15)
        val accepted = (0 until 30).count { p.accept(it * 33_333_333L) }
        assertEquals(15, accepted)
    }

    @Test
    fun pacerKeepsJittery15fps() {
        val p = FramePacer(15)
        val jitter = listOf(0, 8, -6, 10, -9, 3)
        val accepted = (0 until 60).count { p.accept(it * 66_666_667L + jitter[it % jitter.size] * ms) }
        assertEquals(60, accepted)
    }

    @Test
    fun pacerNeverExceedsTargetAt20fps() {
        val p = FramePacer(15)
        val accepted = (0 until 200).count { p.accept(it * 50 * ms) } // 10 s at 20 fps
        assertTrue("accepted $accepted", accepted in 140..151)
    }

    @Test
    fun pacerDoesNotBurstAfterAStall() {
        val p = FramePacer(15)
        assertTrue(p.accept(0))
        assertTrue(p.accept(2000 * ms))
        assertFalse(p.accept(2033 * ms))
        assertTrue(p.accept(2067 * ms))
    }

    private fun gravity(rollDeg: Double): Triple<Float, Float, Float> {
        val r = Math.toRadians(rollDeg)
        return Triple((9.81 * sin(r)).toFloat(), (9.81 * cos(r)).toFloat(), 0.3f)
    }

    @Test
    fun tiltIsRollRelativeToReference() {
        val t = TiltTracker(alpha = 1f)
        val (x0, y0, z0) = gravity(3.0)
        t.update(x0, y0, z0)
        t.markReference()
        assertEquals(0f, t.relativeDeg(), 1e-3f)
        val (x1, y1, z1) = gravity(9.0)
        t.update(x1, y1, z1)
        assertEquals(9f, t.rollDeg(), 1e-3f)
        assertEquals(6f, t.relativeDeg(), 1e-3f)
    }

    @Test
    fun tiltReferenceBeforeAnySampleUsesFirstSample() {
        val t = TiltTracker(alpha = 1f)
        t.markReference()
        assertEquals(0f, t.relativeDeg(), 0f)
        val (x, y, z) = gravity(-20.0)
        t.update(x, y, z)
        assertEquals(0f, t.relativeDeg(), 1e-3f)
        val (x2, y2, z2) = gravity(-26.0)
        t.update(x2, y2, z2)
        assertEquals(-6f, t.relativeDeg(), 1e-3f)
    }

    @Test
    fun tiltLowPassSmoothsSpikes() {
        val t = TiltTracker(alpha = 0.1f)
        val (x, y, z) = gravity(0.0)
        repeat(50) { t.update(x, y, z) }
        t.markReference()
        val (sx, sy, sz) = gravity(45.0)
        t.update(sx, sy, sz) // one jolt
        assertTrue(t.relativeDeg() < 5f)
    }

    @Test
    fun tiltKeepsLastRollWhenFlat() {
        val t = TiltTracker(alpha = 1f)
        val (x, y, z) = gravity(10.0)
        t.update(x, y, z)
        t.update(0.1f, 0.1f, 9.8f)
        assertEquals(10f, t.rollDeg(), 1e-3f)
    }

    @Test
    fun wrapKeepsHalfOpenRange() {
        assertEquals(-170f, TiltTracker.wrap(190f), 1e-4f)
        assertEquals(180f, TiltTracker.wrap(-180f), 1e-4f)
        assertEquals(10f, TiltTracker.wrap(370f), 1e-4f)
    }

    @Test
    fun fpsPickerPrefersFixedThenHighFloor() {
        assertEquals(15 to 15, FpsRangePicker.pick(listOf(7 to 30, 15 to 30, 15 to 15, 10 to 15), 15))
        assertEquals(15 to 30, FpsRangePicker.pick(listOf(7 to 30, 15 to 30, 10 to 15), 15))
        assertEquals(10 to 15, FpsRangePicker.pick(listOf(7 to 30, 10 to 15, 7 to 15), 15))
        assertNull(FpsRangePicker.pick(listOf(24 to 30), 15))
    }

    @Test
    fun lensPickerChoosesWidestFov() {
        val main = LensInfo("0", 5.6f, 6.4f)
        val ultra = LensInfo("2", 1.9f, 5.0f)
        val tele = LensInfo("3", 12f, 4.0f)
        assertEquals("2", LensPicker.widest(listOf(main, ultra, tele))?.id)
        assertTrue(ultra.fovDeg > 100)
        assertNull(LensPicker.widest(listOf(LensInfo("x", 0f, 4f))))
    }
}
