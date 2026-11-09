// Both capture tiers. Each hands back the read end of a pipe with interleaved s16le PCM,
// which the Rust engine reads; closing the write end tells it the capture ended.

package com.shawket.groupplay

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import android.util.Log
import rikka.shizuku.Shizuku
import java.io.FileOutputStream
import java.io.IOException

object CaptureManager {
    private const val TAG = "gp-capture"
    private val main = Handler(Looper.getMainLooper())

    /** Called (main thread) when a running capture stops on its own. */
    var onStopped: ((String) -> Unit)? = null

    // ---------------------------------------------------------------- Shizuku / output mode

    private var shell: IShellCapture? = null
    private var shellConn: ServiceConnection? = null
    private var shellArgs: Shizuku.UserServiceArgs? = null
    private val pendingShell = mutableListOf<(Result<IShellCapture>) -> Unit>()
    var mode: String? = null
        private set

    fun shizukuInstalled(ctx: Context): Boolean = try {
        ctx.packageManager.getPackageInfo("moe.shizuku.privileged.api", 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    fun shizukuRunning(): Boolean = try { Shizuku.pingBinder() } catch (_: Throwable) { false }

    fun shizukuPermission(): Boolean = try {
        shizukuRunning() && !Shizuku.isPreV11() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    } catch (_: Throwable) {
        false
    }

    fun shizukuUid(): Int? = try { if (shizukuRunning()) Shizuku.getUid() else null } catch (_: Throwable) { null }

    /** Binds (once) the shell-side capture service. `done` runs on the main thread. */
    fun withShell(done: (Result<IShellCapture>) -> Unit) {
        main.post {
            shell?.let { s ->
                if (s.asBinder().isBinderAlive) {
                    done(Result.success(s)); return@post
                }
                shell = null
            }
            if (!shizukuRunning()) {
                done(Result.failure(IllegalStateException("Shizuku is not running. Open Shizuku and start it."))); return@post
            }
            if (!shizukuPermission()) {
                done(Result.failure(IllegalStateException("Group Play does not have Shizuku permission yet."))); return@post
            }
            if (Shizuku.getVersion() < 11) {
                done(Result.failure(IllegalStateException("Shizuku is too old; update it."))); return@post
            }
            pendingShell.add(done)
            if (shellConn != null) return@post
            val args = Shizuku.UserServiceArgs(ComponentName(BuildConfig.APPLICATION_ID, ShellCaptureService::class.java.name))
                .daemon(false)
                .processNameSuffix("capture")
                .debuggable(BuildConfig.DEBUG)
                .version(BuildConfig.VERSION_CODE)
            val conn = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                    val s = if (binder != null && binder.pingBinder()) IShellCapture.Stub.asInterface(binder) else null
                    shell = s
                    val waiting = pendingShell.toList()
                    pendingShell.clear()
                    waiting.forEach { cb ->
                        cb(if (s != null) Result.success(s) else Result.failure(IllegalStateException("capture service binder is dead")))
                    }
                }

                override fun onServiceDisconnected(name: ComponentName?) {
                    Log.w(TAG, "shell capture service disconnected")
                    shell = null
                    shellConn = null
                    if (mode == "output") {
                        mode = null
                        onStopped?.invoke("the capture service stopped (Shizuku restarted?)")
                    }
                }
            }
            shellConn = conn
            shellArgs = args
            try {
                Shizuku.bindUserService(args, conn)
            } catch (e: Throwable) {
                shellConn = null
                val waiting = pendingShell.toList()
                pendingShell.clear()
                waiting.forEach { it(Result.failure(e)) }
            }
            // don't wait forever for a service that never comes up
            main.postDelayed({
                if (pendingShell.isNotEmpty()) {
                    val waiting = pendingShell.toList()
                    pendingShell.clear()
                    waiting.forEach { it(Result.failure(IllegalStateException("Shizuku did not start the capture service within 10 s"))) }
                }
            }, 10_000)
        }
    }

    /** Whole-output capture. `done` gets a detached fd (caller owns it) on the main thread. */
    fun startOutput(sampleRate: Int, channels: Int, done: (Result<Int>) -> Unit) {
        withShell { r ->
            r.onFailure { done(Result.failure(it)); return@withShell }
            val s = r.getOrThrow()
            Thread {
                val res = try {
                    stopPlaybackInternal()
                    val pfd = s.start(sampleRate, channels)
                    Log.i(TAG, "output capture started: ${s.info()}")
                    Result.success(pfd.detachFd())
                } catch (e: Throwable) {
                    Log.e(TAG, "output capture failed", e)
                    Result.failure<Int>(IllegalStateException(e.message ?: e.javaClass.simpleName))
                }
                main.post {
                    if (res.isSuccess) mode = "output"
                    done(res)
                }
            }.start()
        }
    }

    // ---------------------------------------------------------------- MediaProjection / playback mode

    private var projection: MediaProjection? = null
    private var playbackRecord: AudioRecord? = null
    private var playbackThread: Thread? = null
    @Volatile private var playbackRunning = false

    /** Set by [SessionService] once it holds a MediaProjection. */
    fun projectionReady(p: MediaProjection) {
        projection?.let { if (it != p) it.stop() }
        projection = p
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                Log.i(TAG, "projection stopped")
                if (projection == p) projection = null
                if (mode == "playback") {
                    stopPlaybackInternal()
                    mode = null
                    main.post { onStopped?.invoke("screen-capture permission was revoked") }
                }
            }
        }, main)
    }

    @SuppressLint("MissingPermission")
    fun startPlayback(sampleRate: Int, channels: Int): Int {
        val p = projection ?: throw IllegalStateException("no MediaProjection")
        stopPlaybackInternal()
        stopShellCapture()
        val config = AudioPlaybackCaptureConfiguration.Builder(p)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .excludeUid(Process.myUid()) // our own synced playback must not loop back in
            .build()
        val channelMask = if (channels == 1) AudioFormat.CHANNEL_IN_MONO else AudioFormat.CHANNEL_IN_STEREO
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(sampleRate)
            .setChannelMask(channelMask)
            .build()
        val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord.Builder()
            .setAudioPlaybackCaptureConfig(config)
            .setAudioFormat(format)
            .setBufferSizeInBytes(maxOf(minBuf, 4096) * 4)
            .build()
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw IllegalStateException("playback capture AudioRecord not initialized")
        }
        rec.startRecording()
        val pipe = ParcelFileDescriptor.createPipe()
        val out = FileOutputStream(pipe[1].fileDescriptor)
        playbackRecord = rec
        playbackRunning = true
        val bytesPerRead = sampleRate / 100 * channels * 2 // 10 ms
        playbackThread = Thread({
            val buf = ByteArray(bytesPerRead)
            var reason = "capture ended"
            try {
                while (playbackRunning) {
                    val n = rec.read(buf, 0, buf.size)
                    if (n < 0) {
                        reason = "AudioRecord error $n"
                        break
                    }
                    if (n > 0) out.write(buf, 0, n)
                }
            } catch (e: IOException) {
                reason = "engine closed the pipe"
            } finally {
                try { out.close() } catch (_: IOException) {}
                try { pipe[1].close() } catch (_: IOException) {}
                try { rec.stop() } catch (_: Throwable) {}
                rec.release()
                Log.i(TAG, "playback capture thread done: $reason")
            }
        }, "gp-playback-capture").apply { start() }
        mode = "playback"
        Log.i(TAG, "playback capture started at $sampleRate Hz x $channels")
        return pipe[0].detachFd()
    }

    private fun stopPlaybackInternal() {
        playbackRunning = false
        playbackThread?.join(500)
        playbackThread = null
        playbackRecord = null
    }

    private fun stopShellCapture() {
        val s = shell ?: return
        try { s.stop() } catch (_: Throwable) {}
    }

    fun stopAll() {
        stopPlaybackInternal()
        stopShellCapture()
        projection?.stop()
        projection = null
        mode = null
    }

    /** Releases the Shizuku service process entirely. */
    fun unbindShell() {
        val args = shellArgs ?: return
        try { Shizuku.unbindUserService(args, shellConn, true) } catch (_: Throwable) {}
        shell = null
        shellConn = null
    }

    fun playbackSupported() = Build.VERSION.SDK_INT >= 29
    fun outputSupported() = Build.VERSION.SDK_INT >= 31
}
