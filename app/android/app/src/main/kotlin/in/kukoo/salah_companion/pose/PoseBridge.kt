package `in`.kukoo.salah_companion.pose

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.camera.view.PreviewView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Flutter <-> native pose engine bridge.
 *
 * - MethodChannel [METHOD_CHANNEL]: `start` (args: token, width, height, fps, lens, preferGpu),
 *   `stop`, and `cameraPermission` (args: request) -> granted. The permission request is done
 *   here rather than with a plugin: permission_handler_android 14.x needs compileSdk 37.
 * - EventChannel [EVENT_CHANNEL]: frames and heartbeats as Float32 lists ([PoseWire]); errors
 *   and info as maps `{event: error|started|engine, token, ...}`.
 * - Platform view [PREVIEW_VIEW_TYPE]: a CameraX PreviewView for the placement check. It
 *   shows the camera only while a session is running; it never sends images to Dart.
 *
 * The activity's ON_STOP (no longer visible) stops a running session (camera released) and
 * reports error code `paused`, which Dart maps to Interruption.appBackgrounded. ON_PAUSE alone
 * (a transparent dialog, the assistant, a multi-window focus change) keeps the session: Dart
 * ignores `inactive` too, and CameraX is bound to the session's own lifecycle, not the
 * activity's, so the camera keeps running while the activity is merely paused.
 */
class PoseBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler, DefaultLifecycleObserver {
    private val context: Context = activity.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private var pendingPermission: MethodChannel.Result? = null
    private val methods = MethodChannel(messenger, METHOD_CHANNEL)
    private val events = EventChannel(messenger, EVENT_CHANNEL)
    private var sink: EventChannel.EventSink? = null
    private var session: PoseSession? = null
    private var previewView: PreviewView? = null

    val previewFactory: PlatformViewFactory = object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
            PreviewPlatformView(context)
    }

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val token = call.argument<Int>("token")
                if (token == null) {
                    result.error("badArgs", "token is required", null)
                    return
                }
                val config = SessionConfig(
                    token = token,
                    width = call.argument<Int>("width") ?: 480,
                    height = call.argument<Int>("height") ?: 640,
                    fps = call.argument<Int>("fps") ?: 15,
                    lens = call.argument<String>("lens") ?: "rear",
                    preferGpu = call.argument<Boolean>("preferGpu") ?: true,
                )
                session?.stop()
                val s = PoseSession(context, config, ::emitFromAnyThread)
                session = s
                s.setPreviewView(previewView)
                s.start()
                result.success(null)
            }
            "stop" -> {
                stopSession()
                result.success(null)
            }
            "cameraPermission" -> {
                if (hasCameraPermission()) {
                    result.success(true)
                } else if (call.argument<Boolean>("request") != true) {
                    result.success(false)
                } else if (pendingPermission != null) {
                    result.error("busy", "A permission request is already showing", null)
                } else {
                    pendingPermission = result
                    ActivityCompat.requestPermissions(
                        activity, arrayOf(Manifest.permission.CAMERA), PERMISSION_REQUEST,
                    )
                }
            }
            else -> result.notImplemented()
        }
    }

    /** Forwarded from the activity. Returns true if the request was ours. */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val result = pendingPermission ?: return true
        pendingPermission = null
        result.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
        return true
    }

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onStop(owner: LifecycleOwner) {
        session?.fail("paused", "The app is no longer visible")
        session = null
    }

    override fun onDestroy(owner: LifecycleOwner) {
        dispose()
    }

    fun dispose() {
        stopSession()
        pendingPermission?.success(false)
        pendingPermission = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    private fun stopSession() {
        session?.stop()
        session = null
    }

    /** Events keep their order: one queue (the engine thread) posts to one queue (main). */
    private fun emitFromAnyThread(event: Any) {
        main.post { sink?.success(event) }
    }

    private inner class PreviewPlatformView(context: Context) : PlatformView {
        // COMPATIBLE = TextureView, which composes with Flutter's platform views.
        private val view = PreviewView(context).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FIT_CENTER
        }

        init {
            previewView = view
            session?.setPreviewView(view)
        }

        override fun getView(): View = view

        override fun dispose() {
            if (previewView === view) {
                previewView = null
                session?.setPreviewView(null)
            }
        }
    }

    companion object {
        const val METHOD_CHANNEL = "salah_companion/pose"
        const val EVENT_CHANNEL = "salah_companion/pose/events"
        const val PREVIEW_VIEW_TYPE = "salah_companion/pose/preview"
        private const val PERMISSION_REQUEST = 4207
    }
}
