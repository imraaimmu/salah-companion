package `in`.kukoo.salah_companion.pose

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FrameLayoutTest {
    @Test
    fun packedRowsAreCopiedInOneGo() {
        val l = FrameLayout.of(640, 480, 640 * 4, 4, 640 * 480 * 4)!!
        assertTrue(l.packed)
        assertEquals(640 * 4, l.rowBytes)
        assertEquals(640 * 480 * 4, l.packedBytes(480))
    }

    @Test
    fun paddedRowsAreCompacted() {
        val stride = 640 * 4 + 64
        val l = FrameLayout.of(640, 480, stride, 4, stride * 480)!!
        assertFalse(l.packed)
        assertEquals(stride, l.rowStride)
        assertEquals(640 * 4, l.rowBytes)
    }

    @Test
    fun aShortLastRowIsAccepted() {
        val stride = 640 * 4 + 64
        val l = FrameLayout.of(640, 480, stride, 4, stride * 479 + 640 * 4)!!
        assertFalse(l.packed)
        assertEquals(640 * 4, l.rowBytes)
    }

    @Test
    fun unusableLayoutsFallBack() {
        assertNull(FrameLayout.of(640, 480, 640 * 4, 2, 640 * 480 * 4)) // not RGBA
        assertNull(FrameLayout.of(640, 480, 640 * 3, 4, 640 * 480 * 4)) // stride too short
        assertNull(FrameLayout.of(640, 480, 640 * 4, 4, 640 * 479 * 4)) // buffer too small
        assertNull(FrameLayout.of(0, 480, 0, 4, 0))
    }
}
