// Debug builds only. Verifies a capture tier without the UI:
//   adb shell am broadcast -n com.shawket.tutti/.DebugProbeReceiver --es mode output --ei seconds 5
// Plays a 440 Hz tone from this app (REMOTE_SUBMIX captures all media output, ours included),
// reads the capture pipe and logs bytes and RMS under the tag "tutti-probe".

package com.shawket.tutti

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import java.io.FileInputStream
import kotlin.math.PI
import kotlin.math.sin
import kotlin.math.sqrt

class DebugProbeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val mode = intent.getStringExtra("mode") ?: "output"
        val seconds = intent.getIntExtra("seconds", 5)
        val tone = intent.getBooleanExtra("tone", true)
        val pending = goAsync()
        Log.i(TAG, "probe: mode=$mode seconds=$seconds shizukuRunning=${CaptureManager.shizukuRunning()} permission=${CaptureManager.shizukuPermission()} uid=${CaptureManager.shizukuUid()}")
        if (mode == "grant") {
            try { rikka.shizuku.Shizuku.requestPermission(77) } catch (e: Throwable) { Log.e(TAG, "probe: requestPermission failed", e) }
            pending.finish(); return
        }
        if (mode != "output") {
            Log.i(TAG, "probe: only 'output' can run without the activity (playback needs the consent dialog)")
            pending.finish(); return
        }
        val t0 = SystemClock.elapsedRealtime()
        CaptureManager.startOutput(48000, 2) { r ->
            r.onFailure {
                Log.e(TAG, "probe: start failed: ${it.message}")
                pending.finish()
            }
            r.onSuccess { fd ->
                Log.i(TAG, "probe: capture started in ${SystemClock.elapsedRealtime() - t0} ms, fd=$fd")
                Thread {
                    val player = if (tone) playTone(seconds + 1) else null
                    val input = FileInputStream(ParcelFileDescriptor.adoptFd(fd).fileDescriptor)
                    val buf = ByteArray(3840)
                    var total = 0L
                    var firstByteMs = -1L
                    val end = SystemClock.elapsedRealtime() + seconds * 1000L
                    var sumSq = 0.0
                    var samples = 0L
                    var windowSq = 0.0
                    var windowN = 0L
                    var lastLog = SystemClock.elapsedRealtime()
                    while (SystemClock.elapsedRealtime() < end) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        if (firstByteMs < 0) firstByteMs = SystemClock.elapsedRealtime() - t0
                        total += n
                        var i = 0
                        while (i + 1 < n) {
                            val s = ((buf[i + 1].toInt() shl 8) or (buf[i].toInt() and 0xff)).toShort().toDouble()
                            sumSq += s * s; windowSq += s * s
                            samples++; windowN++
                            i += 2
                        }
                        if (SystemClock.elapsedRealtime() - lastLog >= 1000) {
                            Log.i(TAG, "probe: +1s rms=${"%.1f".format(sqrt(windowSq / maxOf(windowN, 1)))} bytes=$total")
                            windowSq = 0.0; windowN = 0; lastLog = SystemClock.elapsedRealtime()
                        }
                    }
                    val rms = sqrt(sumSq / maxOf(samples, 1))
                    val rate = total / 4.0 / seconds
                    Log.i(TAG, "probe: DONE bytes=$total (~${"%.0f".format(rate)} frames/s) firstByte=${firstByteMs}ms rms=${"%.1f".format(rms)}")
                    input.close()
                    player?.let { it.stop(); it.release() }
                    CaptureManager.stopAll()
                    pending.finish()
                }.start()
            }
        }
    }

    private fun playTone(seconds: Int): AudioTrack {
        val rate = 48000
        val frames = rate * seconds
        val data = ShortArray(frames * 2)
        for (i in 0 until frames) {
            val v = (sin(2 * PI * 440.0 * i / rate) * 12000).toInt().toShort()
            data[2 * i] = v; data[2 * i + 1] = v
        }
        val track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(data.size * 2)
            .build()
        track.write(data, 0, data.size)
        track.play()
        return track
    }

    companion object {
        private const val TAG = "tutti-probe"
    }
}
