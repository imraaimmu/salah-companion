package `in`.kukoo.salah_companion

import `in`.kukoo.salah_companion.pose.PoseBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var poseBridge: PoseBridge? = null
    private var deviceChannel: DeviceChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bridge = PoseBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        flutterEngine.platformViewsController.registry
            .registerViewFactory(PoseBridge.PREVIEW_VIEW_TYPE, bridge.previewFactory)
        lifecycle.addObserver(bridge)
        poseBridge = bridge
        deviceChannel = DeviceChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (poseBridge?.onRequestPermissionsResult(requestCode, grantResults) != true) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        poseBridge?.let {
            lifecycle.removeObserver(it)
            it.dispose()
        }
        poseBridge = null
        deviceChannel?.dispose()
        deviceChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
