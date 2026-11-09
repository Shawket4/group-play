// Foreground service: keeps a host or listener running with the screen off, and holds the
// MediaProjection while basic capture runs (Android requires a mediaProjection-type service).

package com.shawket.tutti

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.util.Log

class SessionService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: lastTitle
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: lastText
        lastTitle = title
        lastText = text
        when (intent?.action) {
            ACTION_STOP -> {
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_PROJECTION -> {
                val code = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
                @Suppress("DEPRECATION")
                val data: Intent? = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java) else intent.getParcelableExtra(EXTRA_RESULT_DATA)
                // the service must already be a mediaProjection foreground service before
                // getMediaProjection() on Android 14+
                startForegroundCompat(title, text, projection = true)
                val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                val p = try { if (data != null) mpm.getMediaProjection(code, data) else null } catch (e: Throwable) {
                    Log.e(TAG, "getMediaProjection failed", e); null
                }
                val cb = pendingProjection
                pendingProjection = null
                if (p != null) {
                    CaptureManager.projectionReady(p)
                    cb?.invoke(null)
                } else {
                    cb?.invoke("could not get screen-capture permission")
                }
            }
            else -> startForegroundCompat(title, text, projection = false)
        }
        return START_NOT_STICKY
    }

    private fun startForegroundCompat(title: String, text: String, projection: Boolean) {
        val n = notification(this, title, text)
        if (Build.VERSION.SDK_INT >= 29) {
            var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            if (projection) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            startForeground(NOTIFICATION_ID, n, type)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE) else @Suppress("DEPRECATION") stopForeground(true)
    }

    override fun onDestroy() {
        CaptureManager.stopAll()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "tutti-service"
        const val ACTION_START = "com.shawket.tutti.START"
        const val ACTION_STOP = "com.shawket.tutti.STOP"
        const val ACTION_PROJECTION = "com.shawket.tutti.PROJECTION"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        private const val CHANNEL_ID = "tutti_session"
        private const val NOTIFICATION_ID = 7

        private var lastTitle = "Tutti"
        private var lastText = "Session running"

        /** Result of the next ACTION_PROJECTION: null = ok, else an error message. */
        var pendingProjection: ((String?) -> Unit)? = null

        fun start(ctx: Context, title: String, text: String) {
            val i = Intent(ctx, SessionService::class.java).setAction(ACTION_START).putExtra(EXTRA_TITLE, title).putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }

        fun stop(ctx: Context) {
            ctx.startService(Intent(ctx, SessionService::class.java).setAction(ACTION_STOP))
        }

        fun withProjection(ctx: Context, resultCode: Int, data: Intent, done: (String?) -> Unit) {
            pendingProjection = done
            val i = Intent(ctx, SessionService::class.java)
                .setAction(ACTION_PROJECTION)
                .putExtra(EXTRA_RESULT_CODE, resultCode)
                .putExtra(EXTRA_RESULT_DATA, data)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }

        private fun notification(ctx: Context, title: String, text: String): Notification {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Tutti session", NotificationManager.IMPORTANCE_LOW))
            }
            val open = PendingIntent.getActivity(
                ctx, 0,
                Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CHANNEL_ID) else @Suppress("DEPRECATION") Notification.Builder(ctx)
            return b.setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setOngoing(true)
                .setContentIntent(open)
                .build()
        }
    }
}
