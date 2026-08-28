package com.javp.javp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Foreground service so offline downloads keep running when the UI is
 * backgrounded. Android 12+ otherwise freezes a cached process; a local
 * notification alone does not promote the app to foreground.
 *
 * Type is [ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC]. Android 15 forbids
 * starting dataSync from a BOOT_COMPLETED receiver — [start] is only called
 * from the Dart MethodChannel while a download is already in progress, never
 * from [com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver].
 */
class DownloadKeepAliveService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        acquireWakeLock()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Not sticky: a process kill ends Dart downloads, so recreating the
        // FGS with a null intent would leave an orphan notification/wake lock.
        if (intent == null || intent.action == ACTION_STOP) {
            stopForegroundAndSelf()
            return START_NOT_STICKY
        }
        val title = intent.getStringExtra(EXTRA_TITLE) ?: "Downloads"
        val text = intent.getStringExtra(EXTRA_TEXT) ?: ""
        val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
        val indeterminate = intent.getBooleanExtra(EXTRA_INDETERMINATE, true)
        showForeground(title, text, progress, indeterminate)
        return START_NOT_STICKY
    }

    // shortService (API 34+)
    override fun onTimeout(startId: Int) {
        stopForegroundAndSelf()
    }

    // dataSync / mediaProcessing (API 35+); default body is empty — must stop.
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopForegroundAndSelf()
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        releaseWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    internal fun applyNotification(
        title: String,
        text: String,
        progress: Int,
        indeterminate: Boolean,
    ) {
        showForeground(title, text, progress, indeterminate)
    }

    private fun showForeground(
        title: String,
        text: String,
        progress: Int,
        indeterminate: Boolean,
    ) {
        ensureChannel()
        val notification = buildNotification(title, text, progress, indeterminate)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(
        title: String,
        text: String,
        progress: Int,
        indeterminate: Boolean,
    ): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val pct = progress.coerceIn(0, 100)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(pending)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setProgress(100, pct, indeterminate || pct <= 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(
                Notification.FOREGROUND_SERVICE_IMMEDIATE,
            )
        }
        return builder.build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Downloads",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Offline download progress"
                setSound(null, null)
                enableVibration(false)
            },
        )
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(POWER_SERVICE) as? PowerManager ?: return
        val lock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            WAKE_LOCK_TAG,
        )
        lock.setReferenceCounted(false)
        try {
            // Cap matches Android 15 dataSync FGS time limit.
            lock.acquire(WAKE_LOCK_TIMEOUT_MS)
            wakeLock = lock
        } catch (_: Exception) {
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    private fun stopForegroundAndSelf() {
        if (instance === this) instance = null
        releaseWakeLock()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    companion object {
        const val CHANNEL_ID = "downloads"
        const val NOTIFICATION_ID = 0x43F00000
        private const val ACTION_START = "com.javp.javp.DOWNLOAD_KEEPALIVE_START"
        private const val ACTION_STOP = "com.javp.javp.DOWNLOAD_KEEPALIVE_STOP"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_PROGRESS = "progress"
        private const val EXTRA_INDETERMINATE = "indeterminate"
        private const val WAKE_LOCK_TAG = "javp:download"
        private const val WAKE_LOCK_TIMEOUT_MS = 6L * 60L * 60L * 1000L

        @Volatile
        private var instance: DownloadKeepAliveService? = null

        fun start(
            context: Context,
            title: String,
            text: String,
            progress: Int,
            indeterminate: Boolean,
        ) {
            val running = instance
            if (running != null) {
                running.applyNotification(title, text, progress, indeterminate)
                return
            }
            val app = context.applicationContext
            val intent = Intent(app, DownloadKeepAliveService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
                putExtra(EXTRA_PROGRESS, progress)
                putExtra(EXTRA_INDETERMINATE, indeterminate)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                app.startForegroundService(intent)
            } else {
                app.startService(intent)
            }
        }

        fun stop(context: Context) {
            val app = context.applicationContext
            val running = instance
            if (running != null) {
                running.stopForegroundAndSelf()
                return
            }
            try {
                app.stopService(Intent(app, DownloadKeepAliveService::class.java))
            } catch (_: Exception) {
            }
        }
    }
}
