package `in`.kukoo.salah_companion

import android.media.AudioDeviceInfo
import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceChannelTest {
    @Test
    fun speakerOnly() {
        val m = DeviceChannel.audioStatus(7, 15, listOf(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER))
        assertEquals(mapOf("volume" to 7, "maxVolume" to 15, "bluetoothA2dp" to false), m)
    }

    @Test
    fun bluetoothA2dpConnected() {
        val m = DeviceChannel.audioStatus(
            0,
            15,
            listOf(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP),
        )
        assertEquals(true, m["bluetoothA2dp"])
        assertEquals(0, m["volume"])
    }

    @Test
    fun scoHeadsetIsNotMediaOutput() {
        val m = DeviceChannel.audioStatus(5, 15, listOf(AudioDeviceInfo.TYPE_BLUETOOTH_SCO))
        assertEquals(false, m["bluetoothA2dp"])
    }
}
