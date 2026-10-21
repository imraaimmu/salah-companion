package `in`.kukoo.salah_companion

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `salah_companion/device`: `filesDir` -> the app's private files folder (for the settings
 * file), and `audioStatus` -> `{volume, maxVolume, bluetoothA2dp}` for the
 * setup screen's audio check (docs/SPEC.md setup step 6). Reads only; changes nothing and
 * needs no permission (getDevices does not need BLUETOOTH_CONNECT).
 */
class DeviceChannel(context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val appContext = context.applicationContext
    private val audio = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val channel = MethodChannel(messenger, CHANNEL)

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "audioStatus" -> result.success(
                audioStatus(
                    volume = audio.getStreamVolume(AudioManager.STREAM_MUSIC),
                    maxVolume = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
                    outputTypes = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { it.type },
                ),
            )
            "filesDir" -> result.success(appContext.filesDir.absolutePath)
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL = "salah_companion/device"

        /**
         * The channel's reply. A connected A2DP output is where Android routes media, so it
         * counts as "Bluetooth active" (the audio check then reminds the user that recitation
         * plays in the headphones).
         */
        fun audioStatus(volume: Int, maxVolume: Int, outputTypes: List<Int>): Map<String, Any> = mapOf(
            "volume" to volume,
            "maxVolume" to maxVolume,
            "bluetoothA2dp" to outputTypes.any { it == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP },
        )
    }
}
