// MethodChannel "group_play/android" + EventChannel "group_play/android/events".
// The Dart side is lib/platform/android_native.dart; keys here must match it.

package com.shawket.groupplay

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku

class GroupPlayChannel(private val activity: MainActivity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val methods = MethodChannel(messenger, "group_play/android")
    private val main = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null

    private val binderReceived = Shizuku.OnBinderReceivedListener { emitShizuku() }
    private val binderDead = Shizuku.OnBinderDeadListener { emitShizuku() }
    private val shizukuPermissionListener = Shizuku.OnRequestPermissionResultListener { code, result ->
        if (code == SHIZUKU_CODE) {
            val cb = pendingShizuku
            pendingShizuku = null
            cb?.invoke(result == PackageManager.PERMISSION_GRANTED)
            emitShizuku()
        }
    }
    private var pendingShizuku: ((Boolean) -> Unit)? = null

    init {
        methods.setMethodCallHandler(this)
        EventChannel(messenger, "group_play/android/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                events = sink
            }

            override fun onCancel(arguments: Any?) {
                events = null
            }
        })
        try {
            Shizuku.addBinderReceivedListenerSticky(binderReceived)
            Shizuku.addBinderDeadListener(binderDead)
            Shizuku.addRequestPermissionResultListener(shizukuPermissionListener)
        } catch (_: Throwable) {}
        CaptureManager.onStopped = { reason -> emit(mapOf("type" to "captureStopped", "reason" to reason)) }
        NetHelpers.onHotspotStopped = { emit(mapOf("type" to "hotspotStopped")) }
        NetHelpers.onWifiLost = { emit(mapOf("type" to "wifiLost")) }
    }

    fun dispose() {
        try {
            Shizuku.removeBinderReceivedListener(binderReceived)
            Shizuku.removeBinderDeadListener(binderDead)
            Shizuku.removeRequestPermissionResultListener(shizukuPermissionListener)
        } catch (_: Throwable) {}
        methods.setMethodCallHandler(null)
    }

    private fun emit(m: Map<String, Any?>) = main.post { events?.success(m) }

    private fun emitShizuku() = emit(mapOf("type" to "shizuku", "running" to CaptureManager.shizukuRunning(), "permission" to CaptureManager.shizukuPermission()))

    private fun granted(p: String) = activity.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            handle(call, result)
        } catch (e: Throwable) {
            result.error("group_play", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(
                mapOf(
                    "sdkInt" to Build.VERSION.SDK_INT,
                    "manufacturer" to Build.MANUFACTURER,
                    "model" to Build.MODEL,
                    "playbackCaptureSupported" to CaptureManager.playbackSupported(),
                    "outputCaptureSupported" to CaptureManager.outputSupported(),
                    "shizukuInstalled" to CaptureManager.shizukuInstalled(activity),
                    "shizukuRunning" to CaptureManager.shizukuRunning(),
                    "shizukuPermission" to CaptureManager.shizukuPermission(),
                    "shizukuUid" to CaptureManager.shizukuUid(),
                    "recordAudioGranted" to granted(Manifest.permission.RECORD_AUDIO),
                    "notificationsGranted" to (Build.VERSION.SDK_INT < 33 || granted(Manifest.permission.POST_NOTIFICATIONS)),
                ),
            )

            "requestShizukuPermission" -> {
                if (!CaptureManager.shizukuRunning()) {
                    result.error("shizuku", "Shizuku is not running. Open Shizuku and start it.", null); return
                }
                if (CaptureManager.shizukuPermission()) {
                    result.success(true); return
                }
                pendingShizuku = { ok -> main.post { result.success(ok) } }
                Shizuku.requestPermission(SHIZUKU_CODE)
            }

            "requestPermissions" -> {
                val list = call.argument<List<String>>("list") ?: emptyList()
                val wanted = mutableMapOf<String, String?>()
                for (k in list) {
                    wanted[k] = when (k) {
                        "audio" -> Manifest.permission.RECORD_AUDIO
                        "notifications" -> if (Build.VERSION.SDK_INT >= 33) Manifest.permission.POST_NOTIFICATIONS else null
                        "nearbyWifi" -> if (Build.VERSION.SDK_INT >= 33) Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION
                        "location" -> if (Build.VERSION.SDK_INT < 33) Manifest.permission.ACCESS_FINE_LOCATION else null
                        else -> null
                    }
                }
                val missing = wanted.values.filterNotNull().filter { !granted(it) }.distinct()
                val answer = {
                    result.success(wanted.mapValues { (_, p) -> p == null || granted(p) })
                }
                if (missing.isEmpty()) answer() else activity.askPermissions(missing.toTypedArray()) { answer() }
            }

            "startCapture" -> {
                val mode = call.argument<String>("mode") ?: "output"
                val rate = call.argument<Int>("sampleRate") ?: 48000
                val ch = call.argument<Int>("channels") ?: 2
                val reply = { fd: Int -> result.success(mapOf("fd" to fd, "sampleRate" to rate, "channels" to ch)) }
                when (mode) {
                    "output" -> {
                        if (!CaptureManager.outputSupported()) {
                            result.error("capture", "Full capture needs Android 12 or newer.", null); return
                        }
                        CaptureManager.startOutput(rate, ch) { r ->
                            r.onSuccess(reply).onFailure { result.error("capture", it.message, null) }
                        }
                    }
                    "playback" -> {
                        if (!CaptureManager.playbackSupported()) {
                            result.error("capture", "Basic capture needs Android 10 or newer.", null); return
                        }
                        if (!granted(Manifest.permission.RECORD_AUDIO)) {
                            result.error("capture", "Allow audio recording for basic capture.", null); return
                        }
                        val mpm = activity.getSystemService(MediaProjectionManager::class.java)
                        val intent = if (Build.VERSION.SDK_INT >= 34) mpm.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay()) else mpm.createScreenCaptureIntent()
                        activity.askActivityResult(intent) { code, data ->
                            if (code != Activity.RESULT_OK || data == null) {
                                result.error("capture", "Screen-capture permission was declined.", null); return@askActivityResult
                            }
                            SessionService.withProjection(activity, code, data) { err ->
                                main.post {
                                    if (err != null) {
                                        result.error("capture", err, null)
                                    } else {
                                        try {
                                            reply(CaptureManager.startPlayback(rate, ch))
                                        } catch (e: Throwable) {
                                            result.error("capture", e.message, null)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    else -> result.error("capture", "unknown mode $mode", null)
                }
            }

            "startMic" -> {
                if (!granted(Manifest.permission.RECORD_AUDIO)) {
                    result.error("mic", "Allow the microphone so this phone can listen while tuning.", null); return
                }
                val rate = call.argument<Int>("sampleRate") ?: 48000
                result.success(MicRecorder.start(activity, rate))
            }

            "stopMic" -> {
                MicRecorder.stop(activity)
                result.success(null)
            }

            "stopCapture" -> {
                CaptureManager.stopAll()
                result.success(null)
            }

            "startSessionService" -> {
                SessionService.start(activity, call.argument<String>("title") ?: "Group Play", call.argument<String>("text") ?: "Session running")
                result.success(null)
            }

            "stopSessionService" -> {
                CaptureManager.stopAll()
                SessionService.stop(activity)
                result.success(null)
            }

            "startLocalHotspot" -> NetHelpers.startHotspot(activity) { r ->
                r.onSuccess { result.success(it) }.onFailure { result.error("hotspot", it.message, null) }
            }

            "stopLocalHotspot" -> {
                NetHelpers.stopHotspot()
                result.success(null)
            }

            "joinWifi" -> NetHelpers.joinWifi(activity, call.argument<String>("ssid") ?: "", call.argument<String>("passphrase") ?: "") { r ->
                r.onSuccess { result.success(it) }.onFailure { result.error("wifi", it.message, null) }
            }

            "leaveWifi" -> {
                NetHelpers.leaveWifi(activity)
                result.success(null)
            }

            "openShizukuApp" -> {
                val i = activity.packageManager.getLaunchIntentForPackage("moe.shizuku.privileged.api")
                if (i != null) activity.startActivity(i) else openUrl(SHIZUKU_URL)
                result.success(null)
            }

            "openShizukuDownload" -> {
                openUrl(SHIZUKU_URL)
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun openUrl(url: String) {
        activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    companion object {
        private const val SHIZUKU_CODE = 4242
        private const val SHIZUKU_URL = "https://play.google.com/store/apps/details?id=moe.shizuku.privileged.api"
    }
}
