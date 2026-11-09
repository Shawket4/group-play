// The host's microphone for tuning: mono s16le into a pipe whose read end goes to the engine
// (same transport as capture). While it records, other apps' music pauses (transient audio
// focus), so the chirps are heard over silence; it resumes when tuning ends.

package com.shawket.groupplay

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.FileOutputStream
import java.io.IOException

object MicRecorder {
    private const val TAG = "group-play-mic"
    @Volatile private var running = false
    private var thread: Thread? = null
    private var focus: AudioFocusRequest? = null

    /** Starts recording. Returns {fd, sampleRate, channels}; the caller owns fd. */
    fun start(ctx: Context, sampleRate: Int): Map<String, Int> {
        stop(ctx)
        val am = ctx.getSystemService(AudioManager::class.java)
        // UNPROCESSED where the phone has it (no AGC, no noise suppression); otherwise the
        // speech-recognition path, which skips echo cancellation (that would erase our chirp).
        val unprocessed = am.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true"
        val source = if (unprocessed) MediaRecorder.AudioSource.UNPROCESSED else MediaRecorder.AudioSource.VOICE_RECOGNITION
        val mask = AudioFormat.CHANNEL_IN_MONO
        val minBuf = AudioRecord.getMinBufferSize(sampleRate, mask, AudioFormat.ENCODING_PCM_16BIT)
        val rec = try {
            AudioRecord.Builder()
                .setAudioSource(source)
                .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(sampleRate).setChannelMask(mask).build())
                .setBufferSizeInBytes(maxOf(minBuf, 4096) * 4)
                .build()
        } catch (e: SecurityException) {
            throw IllegalStateException("Allow the microphone so this phone can listen while tuning.")
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw IllegalStateException("The microphone is not available.")
        }
        requestFocus(am)
        rec.startRecording()
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            rec.release()
            abandonFocus(am)
            throw IllegalStateException("Another app is using the microphone.")
        }
        val pipe = ParcelFileDescriptor.createPipe()
        val out = FileOutputStream(pipe[1].fileDescriptor)
        running = true
        val bytesPerRead = sampleRate / 100 * 2 // 10 ms
        thread = Thread({
            val buf = ByteArray(bytesPerRead)
            try {
                while (running) {
                    val n = rec.read(buf, 0, buf.size)
                    if (n < 0) break
                    if (n > 0) out.write(buf, 0, n)
                }
            } catch (_: IOException) {
                // the engine is done listening and closed its end
            } finally {
                try { out.close() } catch (_: IOException) {}
                try { pipe[1].close() } catch (_: IOException) {}
                try { rec.stop() } catch (_: Throwable) {}
                rec.release()
                running = false
                Log.i(TAG, "mic stopped")
            }
        }, "gp-mic").apply { start() }
        Log.i(TAG, "mic recording at $sampleRate Hz (${if (unprocessed) "unprocessed" else "voice recognition"})")
        return mapOf("fd" to pipe[0].detachFd(), "sampleRate" to rec.sampleRate, "channels" to 1)
    }

    fun stop(ctx: Context) {
        running = false
        thread?.join(500)
        thread = null
        abandonFocus(ctx.getSystemService(AudioManager::class.java))
    }

    private fun requestFocus(am: AudioManager) {
        if (Build.VERSION.SDK_INT < 26) return
        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            .setOnAudioFocusChangeListener { }
            .build()
        focus = req
        am.requestAudioFocus(req)
    }

    private fun abandonFocus(am: AudioManager) {
        val f = focus ?: return
        focus = null
        if (Build.VERSION.SDK_INT >= 26) am.abandonAudioFocusRequest(f)
    }
}
