// Whole-output capture, run as the adb shell user through a Shizuku UserService.
//
// The AudioRecord setup follows scrcpy (Genymobile/scrcpy, Apache-2.0): REMOTE_SUBMIX can only
// be recorded with CAPTURE_AUDIO_OUTPUT, which the shell user has, and the AudioRecord must be
// attributed to the shell package ("com.android.shell") rather than to our app, hence the
// FakeContext. See scrcpy's audio/AudioDirectCapture.java, FakeContext.java, Workarounds.java.
// While REMOTE_SUBMIX records, Android routes media output into it instead of the speaker.

package com.shawket.groupplay

import android.annotation.SuppressLint
import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Process
import android.util.Log
import java.io.FileOutputStream
import java.io.IOException
import kotlin.system.exitProcess

class ShellCaptureService() : IShellCapture.Stub() {
    // Shizuku 13 prefers a (Context) constructor when present.
    @Suppress("UNUSED_PARAMETER")
    constructor(context: Context) : this()

    private var record: AudioRecord? = null
    private var thread: Thread? = null
    @Volatile private var running = false

    override fun destroy() {
        stop()
        exitProcess(0)
    }

    override fun info(): String =
        "uid=${Process.myUid()} pid=${Process.myPid()} sdk=${Build.VERSION.SDK_INT} ${Build.MANUFACTURER} ${Build.MODEL}"

    @SuppressLint("MissingPermission", "WrongConstant")
    @Synchronized
    override fun start(sampleRate: Int, channels: Int): ParcelFileDescriptor {
        stop()
        if (Build.VERSION.SDK_INT < 31) throw IllegalStateException("full capture needs Android 12+")
        // REMOTE_SUBMIX has its own media volume index (default ~1/3) and audio is attenuated by
        // it before capture: ~30 dB down. Raise it to max BEFORE the route opens (changes while it
        // is open did not apply on the emulator). The phone's speaker is silent during capture anyway.
        raiseSubmixVolume()
        var rec = openRecord(sampleRate, channels)
        // The level is fixed when the route opens, and Android skips a device-volume change while
        // that device is in use: a share started while the boost didn't land stayed quiet however
        // loud the phone was turned up afterwards. If it didn't land: close, raise, reopen once.
        val max = maxMusicVolume()
        val v = submixVolume()
        if (v != null && v < max) {
            Log.w(TAG, "remote_submix media volume $v/$max with the capture open; reopening it at full volume")
            try { rec.stop() } catch (_: Throwable) {}
            rec.release()
            raiseSubmixVolume()
            rec = openRecord(sampleRate, channels)
        }
        Log.i(TAG, "remote_submix media volume ${submixVolume() ?: "unknown"}/$max with the capture open")
        val pipe = try {
            ParcelFileDescriptor.createPipe()
        } catch (e: Throwable) {
            // an open REMOTE_SUBMIX route keeps the phone's speaker silent: never leave one behind
            try { rec.stop() } catch (_: Throwable) {}
            rec.release()
            throw e
        }
        val out = FileOutputStream(pipe[1].fileDescriptor)
        record = rec
        running = true
        // 1024 frames per read: the system captures in blocks of 1024 (scrcpy AudioConfig).
        val bytesPerRead = 1024 * channels * 2
        thread = Thread({
            val buf = ByteArray(bytesPerRead)
            try {
                while (running) {
                    val n = rec.read(buf, 0, buf.size)
                    if (n < 0) {
                        Log.w(TAG, "read error $n")
                        break
                    }
                    if (n > 0) out.write(buf, 0, n)
                }
            } catch (e: IOException) {
                Log.i(TAG, "pipe closed: ${e.message}")
            } finally {
                running = false
                try { out.close() } catch (_: IOException) {}
                try { pipe[1].close() } catch (_: IOException) {}
                try { rec.stop() } catch (_: Throwable) {}
                rec.release()
            }
        }, "gp-shell-capture").apply { start() }
        Log.i(TAG, "REMOTE_SUBMIX capture started at $sampleRate Hz x $channels (${info()})")
        return pipe[0]
    }

    /** A started REMOTE_SUBMIX recording attributed to the shell package. */
    @SuppressLint("MissingPermission", "WrongConstant")
    private fun openRecord(sampleRate: Int, channels: Int): AudioRecord {
        val channelMask = if (channels == 1) AudioFormat.CHANNEL_IN_MONO else AudioFormat.CHANNEL_IN_STEREO
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(sampleRate)
            .setChannelMask(channelMask)
            .build()
        val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT)
        val builder = AudioRecord.Builder()
            .setContext(ShellContext.get())
            .setAudioSource(MediaRecorder.AudioSource.REMOTE_SUBMIX)
            .setAudioFormat(format)
        if (minBuf > 0) builder.setBufferSizeInBytes(8 * minBuf)
        val rec = try {
            builder.build()
        } catch (e: Throwable) {
            throw IllegalStateException("AudioRecord(REMOTE_SUBMIX) failed: ${e.javaClass.simpleName}: ${e.message}")
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw IllegalStateException("AudioRecord(REMOTE_SUBMIX) not initialized")
        }
        try {
            rec.startRecording()
        } catch (e: Throwable) {
            rec.release()
            throw IllegalStateException("REMOTE_SUBMIX did not start: ${e.javaClass.simpleName}: ${e.message}")
        }
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            rec.release()
            throw IllegalStateException("REMOTE_SUBMIX did not start recording")
        }
        return rec
    }

    private fun maxMusicVolume(): Int = try {
        (ShellContext.get().getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager)
            .getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
    } catch (e: Throwable) {
        15
    }

    private fun raiseSubmixVolume() {
        val max = maxMusicVolume()
        // Android 14+: `cmd audio set-device-volume <stream> <index> <native device>` (shell may use it).
        try {
            val p = Runtime.getRuntime().exec(arrayOf("cmd", "audio", "set-device-volume", "3", "$max", "$DEVICE_OUT_REMOTE_SUBMIX"))
            val out = p.inputStream.bufferedReader().readText() + p.errorStream.bufferedReader().readText()
            val code = p.waitFor()
            if (code == 0 && !out.contains("Unknown command", ignoreCase = true) && !out.contains("Error", ignoreCase = true)) {
                // the shell prints the call it makes, not whether it applied: read the index back
                Log.i(TAG, "remote_submix media volume -> $max/$max asked, reads ${submixVolume() ?: "unknown"}: ${out.trim()}")
                return
            }
            Log.w(TAG, "cmd audio set-device-volume: exit $code: ${out.trim()}")
        } catch (e: Throwable) {
            Log.w(TAG, "cmd audio set-device-volume failed: ${e.message}")
        }
        // Android 12/13: AudioSystem.setStreamVolumeIndexAS(stream, index, device), hidden.
        try {
            val cls = Class.forName("android.media.AudioSystem")
            val m = cls.methods.firstOrNull { it.name == "setStreamVolumeIndexAS" }
            if (m != null) {
                val res = when (m.parameterTypes.size) {
                    3 -> m.invoke(null, 3, max, DEVICE_OUT_REMOTE_SUBMIX)
                    4 -> m.invoke(null, 3, max, false, DEVICE_OUT_REMOTE_SUBMIX)
                    else -> null
                }
                Log.i(TAG, "AudioSystem.setStreamVolumeIndexAS -> $res")
            }
        } catch (e: Throwable) {
            Log.w(TAG, "setStreamVolumeIndexAS failed: ${e.message}")
        }
    }

    /** The REMOTE_SUBMIX music volume index (hidden AudioSystem.getStreamVolumeIndex), or null. */
    private fun submixVolume(): Int? = try {
        Class.forName("android.media.AudioSystem")
            .getMethod("getStreamVolumeIndex", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
            .invoke(null, 3, DEVICE_OUT_REMOTE_SUBMIX) as Int
    } catch (e: Throwable) {
        Log.w(TAG, "reading the remote_submix volume failed: ${e.javaClass.simpleName}: ${e.message}")
        null
    }

    @Synchronized
    override fun stop() {
        running = false
        thread?.join(500)
        thread = null
        record = null
    }

    companion object {
        const val TAG = "gp-shell"
        const val DEVICE_OUT_REMOTE_SUBMIX = 0x8000
    }
}

/** Context attributed to the shell package (or root), wrapping the process's system context. */
@SuppressLint("PrivateApi", "DiscouragedPrivateApi")
private class ShellContext private constructor(base: Context) : ContextWrapper(base) {
    private val uid = Process.myUid()
    private val pkg = if (uid == 0) "root" else "com.android.shell"

    override fun getPackageName(): String = pkg
    override fun getOpPackageName(): String = pkg
    override fun getApplicationContext(): Context = this
    override fun createPackageContext(packageName: String, flags: Int): Context = this

    override fun getAttributionSource(): AttributionSource =
        AttributionSource.Builder(uid).setPackageName(pkg).build()

    override fun getDeviceId(): Int = 0

    companion object {
        @Volatile private var instance: ShellContext? = null

        fun get(): ShellContext = instance ?: synchronized(this) {
            instance ?: ShellContext(systemContext()).also { instance = it }
        }

        private fun systemContext(): Context {
            val atClass = Class.forName("android.app.ActivityThread")
            // Shizuku's starter already runs ActivityThread.systemMain(); reuse it if present.
            var at = atClass.getDeclaredMethod("currentActivityThread").invoke(null)
            if (at == null) {
                val ctor = atClass.getDeclaredConstructor().apply { isAccessible = true }
                at = ctor.newInstance()
                atClass.getDeclaredField("sCurrentActivityThread").apply { isAccessible = true }.set(null, at)
                atClass.getDeclaredField("mSystemThread").apply { isAccessible = true }.setBoolean(at, true)
            }
            return atClass.getDeclaredMethod("getSystemContext").invoke(at) as Context
        }
    }
}
