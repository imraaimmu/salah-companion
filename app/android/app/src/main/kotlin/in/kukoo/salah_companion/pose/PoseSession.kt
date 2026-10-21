package `in`.kukoo.salah_companion.pose

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.Surface
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.CameraInfo
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.MirrorMode
import androidx.camera.core.Preview
import androidx.camera.core.UseCase
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarkerResult
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/** Parameters of one session, from Dart's CameraConfig plus engine options. */
data class SessionConfig(
    val token: Int,
    val width: Int = 480,
    val height: Int = 640,
    val fps: Int = 15,
    /** Requested lens: rear | rearUltraWide | front. A missing facing falls back to the other. */
    val lens: String = "rear",
    val preferGpu: Boolean = true,
)

/**
 * One camera + pose session: CameraX (ImageAnalysis, optional Preview) feeding MediaPipe
 * PoseLandmarker in LIVE_STREAM mode, plus the accelerometer for tilt and the heartbeat timer.
 *
 * Threads: CameraX analysis runs on [analysisExecutor]; MediaPipe calls back on its own thread;
 * all emission (frames, heartbeats, errors) is serialised on [engine] (a HandlerThread) so the
 * output order is the order the heartbeat scheduler decided. [emit] is called on that thread;
 * the bridge forwards to the Flutter main thread in order.
 *
 * Camera images never leave this class: each frame is converted, rotated, handed to MediaPipe
 * and dropped. Only landmark numbers are emitted (docs/SPEC.md section 8).
 *
 * Lifecycle: [start] and [stop] are called on the main thread. The camera is bound to this
 * session's own LifecycleOwner, so [stop] releases it immediately and an activity that is
 * merely paused (not stopped) does not stop the camera; the bridge fails the session when the
 * activity stops.
 */
class PoseSession(
    private val context: Context,
    private val config: SessionConfig,
    private val emit: (Any) -> Unit,
) : LifecycleOwner {
    private val registry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = registry

    private val engineThread = HandlerThread("pose-engine").apply { start() }
    private val engine = Handler(engineThread.looper)
    private val main = Handler(context.mainLooper)
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "pose-analysis")
    }

    // Engine-thread state.
    private val scheduler = HeartbeatScheduler()
    private val tilt = TiltTracker()
    private var lastW = config.width
    private var lastH = config.height
    private var framesDelivered = 0L
    private var gpuFailedOver = false

    // Analysis-thread state.
    private val pacer = FramePacer(config.fps)
    private var startNs = -1L
    private var lastSubmittedMs = -1L
    private val frameBitmaps = FrameBitmaps()
    /** Rotation expected from the sensor orientation; checked once against CameraX's. */
    @Volatile private var expectedRotation = -1
    @Volatile private var rotationChecked = false

    /** Guards publishing and closing [landmarker] against [stop]. */
    private val landmarkerLock = Any()
    @Volatile private var landmarker: PoseLandmarker? = null
    @Volatile private var running = false
    @Volatile private var delegateName = "none"

    // Main-thread state.
    private var provider: ProcessCameraProvider? = null
    private var previewView: PreviewView? = null
    private var analysis: ImageAnalysis? = null
    private var preview: Preview? = null
    // Read on the engine thread too (a landmarker created after stop() is closed at once).
    @Volatile private var stopped = false
    private var observedCamera: CameraInfo? = null
    private val failed = java.util.concurrent.atomic.AtomicBoolean(false)

    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager?
    private val sensorListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            tilt.update(event.values[0], event.values[1], event.values[2])
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    }

    private val heartbeatTick = Runnable { onHeartbeatTick() }

    fun start() {
        registry.currentState = Lifecycle.State.CREATED
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            fail("permissionDenied", "Camera permission not granted")
            return
        }
        running = true
        sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
            sensorManager.registerListener(sensorListener, it, SensorManager.SENSOR_DELAY_GAME, engine)
        }
        engine.post { createLandmarker(config.preferGpu) }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (stopped) return@addListener
            try {
                provider = future.get()
                registry.currentState = Lifecycle.State.RESUMED
                bind()
            } catch (e: Exception) {
                fail("cameraUnavailable", "Camera provider failed: ${e.message}")
            }
        }, ContextCompat.getMainExecutor(context))
    }

    /** Attaches or detaches the placement-check preview; rebinds the camera if running. */
    fun setPreviewView(view: PreviewView?) {
        if (previewView === view) return
        previewView = view
        if (running && provider != null) bind()
    }

    /** Releases the camera, sensor, model and threads. Safe to call more than once. */
    fun stop() {
        if (stopped) return
        stopped = true
        running = false
        try {
            provider?.let { p ->
                listOfNotNull<UseCase>(analysis, preview).forEach { p.unbind(it) }
            }
        } catch (e: Exception) {
            Log.w(TAG, "unbind failed", e)
        }
        analysis?.clearAnalyzer()
        analysis = null
        preview = null
        registry.currentState = Lifecycle.State.DESTROYED
        sensorManager?.unregisterListener(sensorListener)
        engine.removeCallbacks(heartbeatTick)
        // Close the model after any in-flight analyze() call, then end the threads.
        val release = Runnable {
            takeLandmarker()?.close()
            frameBitmaps.release()
            engineThread.quitSafely()
        }
        if (!runOnAnalysis(release)) release.run()
        analysisExecutor.shutdown()
    }

    // ---- Camera ------------------------------------------------------------------------

    @OptIn(ExperimentalCamera2Interop::class)
    private fun bind() {
        val p = provider ?: return
        val selection = selectCamera(p) ?: run {
            fail("noCamera", "No camera on this phone")
            return
        }
        val (selector, lensLabel, info) = selection
        val sensorOrientation = info?.let { sensorOrientationOf(it) }
        // Analysis target rotation is always ROTATION_0 (portrait), for both lenses.
        expectedRotation = sensorOrientation?.let {
            CameraOrientation.analysisRotation(it, selection.front, 0)
        } ?: -1
        rotationChecked = false
        val fpsRange = info?.let { availableFpsRanges(it) }?.let { FpsRangePicker.pick(it, config.fps) }

        val resolution = ResolutionSelector.Builder()
            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY)
            // Sizes are given in the target-rotation frame: 480x640 means portrait.
            .setResolutionStrategy(
                ResolutionStrategy(
                    Size(config.width, config.height),
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                ),
            )
            .build()

        val analysisBuilder = ImageAnalysis.Builder()
            .setResolutionSelector(resolution)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
            // Frames are always made upright for the phone's natural (portrait) orientation,
            // whatever the UI orientation: the phone stands in portrait (SPEC section 3).
            .setTargetRotation(Surface.ROTATION_0)
        fpsRange?.let {
            Camera2Interop.Extender(analysisBuilder).setCaptureRequestOption(
                CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(it.first, it.second),
            )
        }
        val newAnalysis = analysisBuilder.build().also {
            it.setAnalyzer(analysisExecutor) { image -> analyzeSafely(image) }
        }

        val view = previewView
        val newPreview = view?.let { v ->
            val b = Preview.Builder()
                .setResolutionSelector(resolution)
                .setTargetRotation(v.display?.rotation ?: Surface.ROTATION_0)
                // The preview (display only) is mirrored for the front camera, like a mirror;
                // Dart mirrors the skeleton overlay to match. Analysis frames are never mirrored.
                .setMirrorMode(MirrorMode.MIRROR_MODE_ON_FRONT_ONLY)
            fpsRange?.let {
                Camera2Interop.Extender(b).setCaptureRequestOption(
                    CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(it.first, it.second),
                )
            }
            b.build().also { it.setSurfaceProvider(v.surfaceProvider) }
        }

        try {
            observedCamera?.cameraState?.removeObservers(this)
            p.unbindAll()
            val useCases = listOfNotNull<UseCase>(newAnalysis, newPreview).toTypedArray()
            val camera = p.bindToLifecycle(this, selector, *useCases)
            analysis = newAnalysis
            preview = newPreview
            observedCamera = camera.cameraInfo
            camera.cameraInfo.cameraState.observe(this) { state -> onCameraState(state) }
            val size = newAnalysis.resolutionInfo?.resolution
            emitOnEngine(
                mapOf(
                    "event" to "started",
                    "token" to config.token,
                    "lens" to lensLabel,
                    "requestedLens" to config.lens,
                    "lensFallback" to selection.fellBack,
                    "sensorOrientation" to (sensorOrientation ?: -1),
                    "fpsRange" to (fpsRange?.let { "${it.first}-${it.second}" } ?: "default"),
                    "analysisSize" to (size?.let { "${it.width}x${it.height}" } ?: "unknown"),
                    "preview" to (newPreview != null),
                ),
            )
        } catch (e: Exception) {
            fail("cameraUnavailable", "Could not open the camera: ${e.message}")
        }
    }

    private fun onCameraState(state: CameraState) {
        val error = state.error ?: return
        val code = when (error.code) {
            CameraState.ERROR_CAMERA_IN_USE, CameraState.ERROR_MAX_CAMERAS_IN_USE -> "cameraInUse"
            CameraState.ERROR_CAMERA_DISABLED -> "cameraDisabled"
            CameraState.ERROR_CAMERA_FATAL_ERROR -> "cameraFatal"
            CameraState.ERROR_DO_NOT_DISTURB_MODE_ENABLED -> "cameraDoNotDisturb"
            CameraState.ERROR_STREAM_CONFIG -> "cameraConfig"
            // CameraX retries these itself; any gap shows up as heartbeats.
            else -> return
        }
        fail(code, "Camera error ${error.code} in state ${state.type}")
    }

    private data class Selection(
        val selector: CameraSelector,
        /** The lens actually opened: "rear", "rearUltraWide" or "front". */
        val label: String,
        val info: CameraInfo?,
        val front: Boolean,
        /** The requested lens was missing and the other facing was opened instead. */
        val fellBack: Boolean,
    )

    @OptIn(ExperimentalCamera2Interop::class)
    private fun selectCamera(p: ProcessCameraProvider): Selection? {
        val all = p.availableCameraInfos
        val choice = LensChoice.resolve(
            config.lens,
            hasFront = all.any { it.lensFacing == CameraSelector.LENS_FACING_FRONT },
            hasBack = all.any { it.lensFacing == CameraSelector.LENS_FACING_BACK },
        ) ?: return null
        val facing = if (choice.front) CameraSelector.LENS_FACING_FRONT else CameraSelector.LENS_FACING_BACK
        val infos = all.filter { it.lensFacing == facing }
        if (config.lens == LensChoice.LENS_REAR_ULTRA_WIDE && !choice.front) {
            val lenses = infos.mapNotNull { lensInfo(it) }
            val widest = LensPicker.widest(lenses)
            if (widest != null) {
                val info = infos.first { Camera2CameraInfo.from(it).cameraId == widest.id }
                val selector = CameraSelector.Builder()
                    .addCameraFilter { list -> list.filter { Camera2CameraInfo.from(it).cameraId == widest.id } }
                    .build()
                // Only one back camera exposed: it is the plain rear camera.
                val label = if (lenses.size > 1) LensChoice.LENS_REAR_ULTRA_WIDE else LensChoice.LENS_REAR
                return Selection(selector, label, info, front = false, fellBack = false)
            }
        }
        val selector = if (choice.front) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
        val info = try {
            selector.filter(infos).firstOrNull()
        } catch (e: Exception) {
            null
        }
        return Selection(selector, choice.label, info, choice.front, choice.fellBack)
    }

    @OptIn(ExperimentalCamera2Interop::class)
    private fun sensorOrientationOf(info: CameraInfo): Int? =
        Camera2CameraInfo.from(info).getCameraCharacteristic(CameraCharacteristics.SENSOR_ORIENTATION)

    @OptIn(ExperimentalCamera2Interop::class)
    private fun lensInfo(info: CameraInfo): LensInfo? {
        val c = Camera2CameraInfo.from(info)
        val focal = c.getCameraCharacteristic(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            ?.minOrNull() ?: return null
        val sensor = c.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE) ?: return null
        return LensInfo(c.cameraId, focal, maxOf(sensor.width, sensor.height))
    }

    @OptIn(ExperimentalCamera2Interop::class)
    private fun availableFpsRanges(info: CameraInfo): List<Pair<Int, Int>>? =
        Camera2CameraInfo.from(info)
            .getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?.map { Pair(it.lower, it.upper) }

    // ---- Analysis (analysis thread) -----------------------------------------------------

    private fun analyzeSafely(image: ImageProxy) {
        try {
            analyze(image)
        } catch (e: Exception) {
            Log.w(TAG, "analyze failed", e)
        } finally {
            image.close()
        }
    }

    private fun analyze(image: ImageProxy) {
        if (!running) return
        val lm = landmarker ?: return
        val ts = image.imageInfo.timestamp
        if (!pacer.accept(ts)) return
        if (startNs < 0) {
            startNs = ts
            engine.post { tilt.markReference() }
        }
        val tMs = (ts - startNs) / 1_000_000
        if (tMs <= lastSubmittedMs) return // MediaPipe needs strictly increasing timestamps.
        lastSubmittedMs = tMs

        if (!rotationChecked) {
            rotationChecked = true
            val expected = expectedRotation
            val actual = image.imageInfo.rotationDegrees
            if (expected >= 0 && expected != actual) {
                // CameraX's value is what the buffer needs; this only flags an odd device.
                Log.w(TAG, "rotationDegrees $actual differs from sensor-orientation math $expected")
            }
        }
        val upright = frameBitmaps.upright(image) ?: return
        // MediaPipe copies the pixels into its own packet inside detectAsync (and never closes
        // or recycles the input), so the reused bitmap can be overwritten by the next frame.
        lm.detectAsync(BitmapImageBuilder(upright).build(), tMs)
    }

    /**
     * Analysis thread. Reuses bitmaps across frames instead of allocating two per frame
     * (ImageProxy.toBitmap plus the rotated copy): the RGBA buffer is copied into [source]
     * (directly when rows are packed, otherwise row by row through a reused scratch buffer,
     * see [FrameLayout]) and, unless already upright, drawn upright into [upright] with
     * [UprightTransform]'s matrix exactly as before. A new frame size reallocates.
     */
    private class FrameBitmaps {
        private var source: Bitmap? = null
        private var upright: Bitmap? = null
        private var canvas: Canvas? = null
        private var scratch: java.nio.ByteBuffer? = null
        private var row: ByteArray? = null
        private val matrix = Matrix()

        fun upright(image: ImageProxy): Bitmap? {
            val w = image.width
            val h = image.height
            val plane = image.planes.firstOrNull() ?: return null
            val buffer = plane.buffer
            val layout = FrameLayout.of(w, h, plane.rowStride, plane.pixelStride, buffer.capacity())
            val src: Bitmap
            if (layout == null) {
                // Unexpected layout: let CameraX convert it (allocates).
                src = image.toBitmap()
            } else {
                src = reuse(source, w, h).also { source = it }
                buffer.rewind()
                if (layout.packed) {
                    src.copyPixelsFromBuffer(buffer)
                } else {
                    src.copyPixelsFromBuffer(compact(buffer, layout, h))
                }
            }
            val xf = UprightTransform(src.width, src.height, image.imageInfo.rotationDegrees)
            if (xf.rotation == 0) return src
            val dst = reuse(upright, xf.uprightW, xf.uprightH)
            if (dst !== upright || canvas == null) {
                upright = dst
                canvas = Canvas(dst)
            }
            matrix.setValues(xf.matrixValues())
            canvas!!.drawBitmap(src, matrix, null)
            if (src !== source) src.recycle()
            return dst
        }

        /** Copies the rows without their padding into the reused scratch buffer. */
        private fun compact(buffer: java.nio.ByteBuffer, layout: FrameLayout, h: Int): java.nio.ByteBuffer {
            val out = scratch?.takeIf { it.capacity() == layout.packedBytes(h) }
                ?: java.nio.ByteBuffer.allocateDirect(layout.packedBytes(h)).also { scratch = it }
            val line = row?.takeIf { it.size == layout.rowBytes }
                ?: ByteArray(layout.rowBytes).also { row = it }
            out.clear()
            for (y in 0 until h) {
                buffer.position(y * layout.rowStride)
                buffer.get(line, 0, layout.rowBytes)
                out.put(line, 0, layout.rowBytes)
            }
            out.rewind()
            return out
        }

        private fun reuse(old: Bitmap?, w: Int, h: Int): Bitmap {
            if (old != null && !old.isRecycled && old.width == w && old.height == h) return old
            old?.recycle()
            return Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        }

        fun release() {
            source?.recycle()
            upright?.recycle()
            source = null
            upright = null
            canvas = null
            scratch = null
            row = null
        }
    }

    // ---- MediaPipe ----------------------------------------------------------------------

    /** Engine thread. GPU first when asked, CPU if the GPU delegate cannot be created. */
    private fun createLandmarker(gpu: Boolean) {
        if (!running) return
        takeLandmarker()?.let { old ->
            // Close after any in-flight analyze() call; inline if the executor is gone.
            if (!runOnAnalysis { old.close() }) old.close()
        }
        val attempts = if (gpu) listOf(Delegate.GPU, Delegate.CPU) else listOf(Delegate.CPU)
        var lastError: Exception? = null
        for (delegate in attempts) {
            try {
                val created = PoseLandmarker.createFromOptions(context, options(delegate))
                val publish = synchronized(landmarkerLock) {
                    if (!stopped) landmarker = created
                    !stopped
                }
                if (!publish) {
                    // stop() ran while the model was loading: nobody else will close it.
                    created.close()
                    return
                }
                delegateName = delegate.name
                emitOnEngine(mapOf("event" to "engine", "token" to config.token, "delegate" to delegate.name))
                return
            } catch (e: Exception) {
                Log.w(TAG, "PoseLandmarker with $delegate failed", e)
                lastError = e
            }
        }
        fail("engineInit", "Pose model failed to load: ${lastError?.message}")
    }

    private fun options(delegate: Delegate): PoseLandmarker.PoseLandmarkerOptions {
        val base = BaseOptions.builder()
            .setModelAssetPath(MODEL_ASSET)
            .setDelegate(delegate)
            .build()
        return PoseLandmarker.PoseLandmarkerOptions.builder()
            .setBaseOptions(base)
            .setRunningMode(RunningMode.LIVE_STREAM)
            .setNumPoses(PoseWire.MAX_PEOPLE)
            .setMinPoseDetectionConfidence(0.5f)
            .setMinPosePresenceConfidence(0.5f)
            .setMinTrackingConfidence(0.5f)
            .setOutputSegmentationMasks(false)
            .setResultListener { result: PoseLandmarkerResult, input: MPImage -> onResult(result, input) }
            .setErrorListener { e: RuntimeException -> engine.post { onEngineError(e) } }
            .build()
    }

    /** MediaPipe thread. */
    private fun onResult(result: PoseLandmarkerResult, input: MPImage) {
        val w = input.width
        val h = input.height
        val people = result.landmarks().take(PoseWire.MAX_PEOPLE).map { person ->
            val out = FloatArray(PoseWire.PERSON_FLOATS)
            for (i in 0 until minOf(person.size, PoseWire.LANDMARKS)) {
                val l = person[i]
                UprightTransform.writeLandmark(
                    out, i * PoseWire.FIELDS, l.x(), l.y(), l.z(), l.visibility().orElse(0f), w, h,
                )
            }
            out
        }
        val tMs = result.timestampMs()
        engine.post { deliverFrame(tMs, w, h, people) }
    }

    /** Engine thread. */
    private fun deliverFrame(tMs: Long, w: Int, h: Int, people: List<FloatArray>) {
        if (!running) return
        if (!scheduler.onFrame(tMs, SystemClock.elapsedRealtime())) {
            Log.d(TAG, "dropped late frame at $tMs ms (${scheduler.droppedLateFrames} so far)")
            return
        }
        framesDelivered++
        lastW = w
        lastH = h
        emit(PoseWire.frame(config.token, tMs, w, h, tilt.relativeDeg(), people))
        scheduleHeartbeat()
    }

    /** Engine thread. */
    private fun onHeartbeatTick() {
        if (!running) return
        for (stamp in scheduler.poll(SystemClock.elapsedRealtime())) {
            emit(PoseWire.heartbeat(config.token, stamp, lastW, lastH))
        }
        scheduleHeartbeat()
    }

    private fun scheduleHeartbeat() {
        engine.removeCallbacks(heartbeatTick)
        val due = scheduler.nextDueAt() ?: return
        engine.postDelayed(heartbeatTick, maxOf(0L, due - SystemClock.elapsedRealtime()))
    }

    /** Engine thread. A GPU delegate that fails before any frame falls back to CPU once. */
    private fun onEngineError(e: RuntimeException) {
        if (!running) return
        Log.w(TAG, "PoseLandmarker error ($delegateName)", e)
        if (delegateName == Delegate.GPU.name && framesDelivered == 0L && !gpuFailedOver) {
            gpuFailedOver = true
            createLandmarker(false)
            return
        }
        fail("engineError", "Pose engine error: ${e.message}")
    }

    // ---- Errors -------------------------------------------------------------------------

    /** Reports an error event and stops the session. Any thread. */
    fun fail(code: String, message: String) {
        if (!failed.compareAndSet(false, true)) return
        val event = mapOf("event" to "error", "token" to config.token, "code" to code, "message" to message)
        running = false
        if (engineThread.isAlive) engine.post { emit(event) } else emit(event)
        main.post { stop() }
    }

    /** Takes the landmarker for closing; null if there is none (or it was taken). */
    private fun takeLandmarker(): PoseLandmarker? = synchronized(landmarkerLock) {
        landmarker.also { landmarker = null }
    }

    /** Runs [block] on the analysis executor; false if it has been shut down. */
    private fun runOnAnalysis(block: Runnable): Boolean =
        try {
            analysisExecutor.execute(block)
            true
        } catch (e: RejectedExecutionException) {
            false
        }

    private fun emitOnEngine(event: Any) {
        engine.post { emit(event) }
    }

    companion object {
        private const val TAG = "PoseSession"

        /** Downloaded at build time by the `downloadPoseModel` Gradle task. */
        const val MODEL_ASSET = "pose_landmarker.task"
    }
}
