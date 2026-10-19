package `in`.kukoo.salah_companion.pose

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HeartbeatSchedulerTest {
    @Test
    fun noHeartbeatsBeforeFirstFrame() {
        val s = HeartbeatScheduler()
        assertNull(s.nextDueAt())
        assertEquals(emptyList<Long>(), s.poll(10_000))
        assertFalse(s.started)
    }

    @Test
    fun noHeartbeatWithin100msOfAFrame() {
        val s = HeartbeatScheduler(periodMs = 100, guardMs = 50)
        assertTrue(s.onFrame(1000, arrivalMs = 5000))
        assertEquals(5150L, s.nextDueAt())
        assertEquals(emptyList<Long>(), s.poll(5149))
    }

    @Test
    fun heartbeatsAreStampedLastFramePlusK100() {
        val s = HeartbeatScheduler(periodMs = 100, guardMs = 50)
        s.onFrame(1000, arrivalMs = 5000)
        assertEquals(listOf(1100L), s.poll(5150))
        assertEquals(5250L, s.nextDueAt())
        assertEquals(emptyList<Long>(), s.poll(5200))
        // A late timer tick catches up with every due heartbeat, in order.
        assertEquals(listOf(1200L, 1300L, 1400L), s.poll(5470))
    }

    @Test
    fun aFrameResetsTheHeartbeatClock() {
        val s = HeartbeatScheduler(periodMs = 100, guardMs = 0)
        s.onFrame(0, arrivalMs = 0)
        assertEquals(listOf(100L, 200L), s.poll(200))
        assertTrue(s.onFrame(250, arrivalMs = 260))
        assertEquals(emptyList<Long>(), s.poll(359))
        assertEquals(listOf(350L), s.poll(360))
    }

    @Test
    fun regularFramesNeverProduceHeartbeats() {
        val s = HeartbeatScheduler()
        var t = 0L
        repeat(100) {
            assertTrue(s.onFrame(t, arrivalMs = t + 40))
            assertEquals(emptyList<Long>(), s.poll(t + 40 + 66))
            t += 67 // 15 fps
        }
    }

    @Test
    fun frameAtOrBeforeAnEmittedHeartbeatIsDropped() {
        val s = HeartbeatScheduler(periodMs = 100, guardMs = 50)
        s.onFrame(1000, arrivalMs = 5000)
        assertEquals(listOf(1100L), s.poll(5150))
        // Captured at 1090 but delivered after heartbeat 1100 went out: dropped.
        assertFalse(s.onFrame(1090, arrivalMs = 5160))
        assertFalse(s.onFrame(1100, arrivalMs = 5161))
        assertEquals(2, s.droppedLateFrames)
        // The heartbeat clock is not reset by a dropped frame.
        assertEquals(listOf(1200L), s.poll(5250))
        // A later frame is accepted and resets the clock.
        assertTrue(s.onFrame(1201, arrivalMs = 5260))
        assertEquals(5410L, s.nextDueAt())
    }

    @Test
    fun outputIsStrictlyIncreasingAndFollowsTheRule() {
        // Frames with a 450 ms gap (camera stall), random-ish delivery latency within guard.
        val frames = listOf(0L, 67L, 133L, 200L, 650L, 717L)
        val latency = listOf(30L, 45L, 35L, 60L, 40L, 50L)
        val s = HeartbeatScheduler(periodMs = 100, guardMs = 50)
        val out = mutableListOf<Pair<String, Long>>()
        var now = 0L
        for (i in frames.indices) {
            val arrival = frames[i] + latency[i]
            while (now < arrival) {
                s.poll(now).forEach { out += "hb" to it }
                now++
            }
            if (s.onFrame(frames[i], arrival)) out += "frame" to frames[i]
        }
        val stamps = out.map { it.second }
        assertEquals(stamps.sorted(), stamps)
        assertEquals(stamps.toSet().size, stamps.size)
        // Frame 200 is delivered at 260, so heartbeats 300, 400, 500 fall due at 410, 510, 610.
        // Heartbeat 600 would be due at 710, but frame 650 is delivered at 690 and resets the
        // clock first: live, a heartbeat is only sent while no frame has arrived.
        assertEquals(
            listOf(
                "frame" to 0L, "frame" to 67L, "frame" to 133L, "frame" to 200L,
                "hb" to 300L, "hb" to 400L, "hb" to 500L,
                "frame" to 650L, "frame" to 717L,
            ),
            out,
        )
    }

    @Test
    fun resetForgetsEverything() {
        val s = HeartbeatScheduler()
        s.onFrame(500, 500)
        s.reset()
        assertNull(s.nextDueAt())
        assertTrue(s.onFrame(10, 10))
    }
}
