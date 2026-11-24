package com.livekit.example.VoiceAssistantFlutter

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
import android.util.Log

// Keeps JARVIS running while the app is in the background, in picture-in-picture or
// with the screen off. Android cuts microphone access for backgrounded apps unless a
// foreground service of the matching type is running.
//
// Two reasons to run, shown in one notification:
// - a call (microphone, agent audio and, when requested, screen capture);
// - the master phone's standby: the on-device "Jarvis" detector, the report stream
//   and spoken alerts. Its notification has Pause/Resume listening buttons.
class JarvisService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE -> MasterBridge.serviceAction("pause")
            ACTION_RESUME -> MasterBridge.serviceAction("resume")
            ACTION_LISTEN -> MasterBridge.serviceAction("listen")
        }
        // Every start made with startForegroundService must reach startForeground,
        // even when the reason to run ended in the meantime (a call hung up while the
        // service was starting): Android kills the app otherwise. So go foreground
        // first, then stop if there is nothing left to do.
        try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                if (screenCapture) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                startForeground(NOTIFICATION_ID, notification, types)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // E.g. microphone permission missing: run without background support.
            Log.e(TAG, "Could not start foreground service", e)
            stopSelf()
        }
        onForegroundReady?.invoke()
        onForegroundReady = null
        if (!call && !standby) {
            @Suppress("DEPRECATION")
            stopForeground(true)
            // Only if no newer start is queued; that one keeps the service running.
            stopSelf(startId)
            return START_NOT_STICKY
        }
        syncWakeLock()
        return START_NOT_STICKY
    }

    override fun onCreate() {
        super.onCreate()
        active = true
    }

    override fun onDestroy() {
        active = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    // The detector must keep running with the screen off; the master phone is
    // expected to stay on its charger.
    private fun syncWakeLock() {
        val needed = standby && listening
        val lock = wakeLock
        if (needed && (lock == null || !lock.isHeld)) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "jarvis:standby").apply {
                setReferenceCounted(false)
                acquire()
            }
        } else if (!needed && lock != null && lock.isHeld) {
            lock.release()
        }
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "J.A.R.V.I.S ativo", NotificationManager.IMPORTANCE_LOW)
            )
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            flags,
        )
        builder
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("J.A.R.V.I.S")
            .setOngoing(true)
            .setContentIntent(open)

        if (call) {
            val hangUp = PendingIntent.getActivity(
                this, 1,
                Intent(this, MainActivity::class.java)
                    .setAction(MainActivity.ACTION_HANG_UP)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                flags,
            )
            builder.setContentText(
                when {
                    screenCapture -> "Ouvindo e vendo sua tela"
                    callAudio -> "Ouvindo · toque para abrir"
                    else -> "Respondendo (microfone fechado)"
                }
            )
            builder.addAction(Notification.Action.Builder(null, "Encerrar", hangUp).build())
        } else {
            builder.setContentText(standbyStatus)
            if (listening) {
                builder.addAction(Notification.Action.Builder(null, "Speak", serviceIntent(ACTION_LISTEN, 3)).build())
                builder.addAction(Notification.Action.Builder(null, "Pause listening", serviceIntent(ACTION_PAUSE, 4)).build())
            } else {
                builder.addAction(Notification.Action.Builder(null, "Resume listening", serviceIntent(ACTION_RESUME, 5)).build())
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    private fun serviceIntent(action: String, code: Int): PendingIntent = PendingIntent.getService(
        this, code,
        Intent(this, JarvisService::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    companion object {
        private const val TAG = "JarvisService"
        private const val CHANNEL_ID = "jarvis_session"
        private const val NOTIFICATION_ID = 1001
        private const val ACTION_PAUSE = "com.livekit.example.VoiceAssistantFlutter.PAUSE_LISTENING"
        private const val ACTION_RESUME = "com.livekit.example.VoiceAssistantFlutter.RESUME_LISTENING"
        private const val ACTION_LISTEN = "com.livekit.example.VoiceAssistantFlutter.LISTEN_NOW"

        @Volatile private var call = false
        @Volatile private var callAudio = true
        @Volatile private var screenCapture = false
        @Volatile private var standby = false
        @Volatile private var listening = true
        @Volatile private var standbyStatus = "Waiting for \"Jarvis\""

        // Called on the main thread once startForeground has run for the latest start().
        var onForegroundReady: (() -> Unit)? = null

        fun setCall(context: Context, active: Boolean, audio: Boolean = true) {
            call = active
            callAudio = audio
            if (!active) screenCapture = false
            sync(context)
        }

        fun setScreenCapture(context: Context, enabled: Boolean) {
            if (enabled) call = true
            screenCapture = enabled
            sync(context, force = true)
        }

        fun setStandby(context: Context, enabled: Boolean, status: String, isListening: Boolean) {
            standby = enabled
            standbyStatus = status
            listening = isListening
            sync(context)
        }

        // True from a start request until the service is destroyed.
        @Volatile private var active = false
        @Volatile private var requested = false

        private fun sync(context: Context, force: Boolean = false) {
            val app = context.applicationContext
            // Never stopService(): it can land before a pending start reaches
            // startForeground and crash the app. The service stops itself instead.
            if (call || standby || force || active || requested) {
                requested = call || standby || force
                val intent = Intent(app, JarvisService::class.java)
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        app.startForegroundService(intent)
                    } else {
                        app.startService(intent)
                    }
                } catch (e: Exception) {
                    // Android 12+ refuses a start from the background; the next update
                    // from the foreground starts it again.
                    Log.w(TAG, "Could not start the service", e)
                    onForegroundReady?.invoke()
                    onForegroundReady = null
                }
            }
        }
    }
}
