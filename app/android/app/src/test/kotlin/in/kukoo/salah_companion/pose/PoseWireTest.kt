package `in`.kukoo.salah_companion.pose

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class PoseWireTest {
    @Test
    fun heartbeatMatchesGoldenVector() {
        // Same vector as app/test/pose/pose_wire_test.dart ("golden heartbeat").
        assertArrayEquals(
            floatArrayOf(1f, 7f, 1f, 3000f, 480f, 640f, 0f, 0f),
            PoseWire.heartbeat(token = 7, tMs = 68536, imageW = 480, imageH = 640),
            0f,
        )
    }

    @Test
    fun frameMatchesGoldenVector() {
        // Same vector as app/test/pose/pose_wire_test.dart ("golden frame").
        val person = FloatArray(PoseWire.PERSON_FLOATS) { i -> (i / 4).toFloat() + (i % 4) * 0.25f }
        val data = PoseWire.frame(token = 3, tMs = 1234, imageW = 480, imageH = 640, tiltDeg = -1.5f, people = listOf(person))
        assertEquals(PoseWire.HEADER + PoseWire.PERSON_FLOATS, data.size)
        assertArrayEquals(floatArrayOf(0f, 3f, 0f, 1234f, 480f, 640f, -1.5f, 1f), data.copyOfRange(0, 8), 0f)
        // Landmark 11 (left shoulder): x = 11, y = 11.25, z = 11.5, conf = 11.75.
        assertArrayEquals(floatArrayOf(11f, 11.25f, 11.5f, 11.75f), data.copyOfRange(8 + 44, 8 + 48), 0f)
    }

    @Test
    fun largeTimestampsStayExact() {
        val t = 4L * 3600 * 1000 + 123 // 4 h: beyond float32's exact integer range as one value
        assertEquals(t, PoseWire.tMs(PoseWire.heartbeat(1, t, 0, 0)))
    }

    @Test
    fun noPeopleAndAtMostThree() {
        assertEquals(PoseWire.HEADER, PoseWire.frame(1, 0, 1, 1, 0f, emptyList()).size)
        val p = FloatArray(PoseWire.PERSON_FLOATS)
        val data = PoseWire.frame(1, 0, 1, 1, 0f, listOf(p, p, p, p))
        assertEquals(3f, data[7], 0f)
        assertEquals(PoseWire.HEADER + 3 * PoseWire.PERSON_FLOATS, data.size)
    }

    @Test(expected = IllegalArgumentException::class)
    fun negativeTimeRejected() {
        PoseWire.heartbeat(1, -1, 0, 0)
    }

    @Test(expected = IllegalArgumentException::class)
    fun wrongPersonSizeRejected() {
        PoseWire.frame(1, 0, 1, 1, 0f, listOf(FloatArray(10)))
    }
}
