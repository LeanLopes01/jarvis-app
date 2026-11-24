package com.livekit.example.VoiceAssistantFlutter

import android.Manifest
import android.app.NotificationManager
import android.app.PictureInPictureParams
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var sessionActive = false
    private var cachedEngine = false

    // The master phone keeps its Flutter engine when this screen closes, so the
    // "Jarvis" detector, the report stream and spoken alerts keep running with the
    // foreground service. Other phones keep the old behaviour. Decided once per
    // screen: master mode switched on in the app takes this effect from the next
    // start, so there is never a second engine.
    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let {
            cachedEngine = true
            return it
        }
        if (!isMasterMode(context)) return null
        cachedEngine = true
        return FlutterEngine(context.applicationContext).also {
            it.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            FlutterEngineCache.getInstance().put(ENGINE_ID, it)
        }
    }

    override fun shouldDestroyEngineWithHost(): Boolean = !cachedEngine

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val app = applicationContext
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jarvis/updates").setMethodCallHandler { call, result ->
            val bridge = UpdatesBridge(this)
            when (call.method) {
                "version" -> result.success(bridge.version())
                "install" -> bridge.install(call.argument<String>("token") ?: "", call.argument<String>("sha256") ?: "", result)
                else -> result.notImplemented()
            }
        }
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jarvis/system").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "startSession" -> {
                        startSession(call.argument<Boolean>("audio") != false)
                        result.success(null)
                    }
                    "stopSession" -> {
                        stopSession()
                        result.success(null)
                    }
                    // Must be called after the screen capture consent was granted and
                    // before the capture starts (Android 14+ requirement).
                    "setScreenCapture" -> {
                        JarvisService.onForegroundReady = { result.success(null) }
                        JarvisService.setScreenCapture(app, call.argument<Boolean>("enabled") == true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MasterBridge.channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jarvis/master").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "standby" -> {
                        JarvisService.setStandby(
                            app,
                            call.argument<Boolean>("enabled") == true,
                            call.argument<String>("status") ?: "",
                            call.argument<Boolean>("listening") != false,
                        )
                        result.success(null)
                    }
                    "beep" -> {
                        beep(call.argument<String>("kind") ?: "done")
                        result.success(null)
                    }
                    "audioContext" -> result.success(audioContext(app))
                    "batteryOptimized" -> {
                        val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(!power.isIgnoringBatteryOptimizations(app.packageName))
                    }
                    "requestBatteryExemption" -> {
                        openSettings(
                            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${app.packageName}"))
                        )
                        result.success(null)
                    }
                    "socialAccess" -> result.success(hasNotificationAccess(app))
                    "openSocialSettings" -> {
                        openSettings(Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS"))
                        result.success(null)
                    }
                    "socialPending" -> {
                        SocialListener.refresh(app)
                        result.success(SocialStore.drain(app))
                    }
                    "socialChannels" -> result.success(SocialStore.channels(app))
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun openSettings(intent: Intent) {
        try {
            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {
            startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    private fun startSession(audio: Boolean) {
        sessionActive = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0)
        }
        JarvisService.setCall(applicationContext, true, audio)
        updatePipParams()
    }

    private fun stopSession() {
        sessionActive = false
        JarvisService.setCall(applicationContext, false)
        updatePipParams()
    }

    // Floating window while a session is running, so Jarvis stays visible over other apps.
    private fun pipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder().setAspectRatio(Rational(1, 1))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(sessionActive).setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    private fun updatePipParams() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) setPictureInPictureParams(pipParams())
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 12+ enters PiP automatically via setAutoEnterEnabled.
        if (sessionActive && Build.VERSION.SDK_INT in Build.VERSION_CODES.O until Build.VERSION_CODES.S) {
            enterPictureInPictureMode(pipParams())
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == ACTION_HANG_UP) channel?.invokeMethod("hangUp", null)
    }

    override fun onResume() {
        super.onResume()
        // Opened again after a reboot or an update: the reminder is no longer needed.
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(BootReceiver.NOTIFICATION_ID)
    }

    override fun onDestroy() {
        // The master phone's engine and service outlive this screen; Flutter stops them.
        if (!cachedEngine) MasterBridge.channel = null // its engine goes with this screen
        if (isFinishing && !cachedEngine) {
            JarvisService.setCall(applicationContext, false)
            JarvisService.setStandby(applicationContext, false, "", false)
        }
        super.onDestroy()
    }

    companion object {
        const val ACTION_HANG_UP = "com.livekit.example.VoiceAssistantFlutter.HANG_UP"
        private const val ENGINE_ID = "jarvis_master"

        // Written by Flutter's shared_preferences (lib/master/event_store.dart).
        fun isMasterMode(context: Context): Boolean =
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getBoolean("flutter.jarvis_master_mode", false) || isWorkMode(context)

        fun isWorkMode(context: Context): Boolean =
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getBoolean("flutter.jarvis_work_mode", false)

        fun isCompanion(context: Context): Boolean =
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getBoolean("flutter.jarvis_companion", false)

        fun hasNotificationAccess(context: Context): Boolean {
            val enabled = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners") ?: return false
            val ours = ComponentName(context, SocialListener::class.java).flattenToString()
            return enabled.split(":").any { it == ours }
        }

        // Do Not Disturb and calls keep spoken alerts silent (cards still appear).
        fun audioContext(context: Context): Map<String, Boolean> {
            val notifications = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val dnd = notifications.currentInterruptionFilter > NotificationManager.INTERRUPTION_FILTER_ALL
            val inCall = audio.mode == AudioManager.MODE_IN_CALL ||
                audio.mode == AudioManager.MODE_IN_COMMUNICATION ||
                audio.mode == AudioManager.MODE_RINGTONE
            return mapOf("dnd" to dnd, "inCall" to inCall)
        }

        private val tones = Handler(Looper.getMainLooper())

        fun beep(kind: String) {
            val (tone, ms) = when (kind) {
                "wake" -> ToneGenerator.TONE_PROP_BEEP to 120
                "error" -> ToneGenerator.TONE_PROP_NACK to 250
                else -> ToneGenerator.TONE_PROP_ACK to 150
            }
            try {
                val generator = ToneGenerator(AudioManager.STREAM_MUSIC, 60)
                generator.startTone(tone, ms)
                tones.postDelayed({ generator.release() }, ms + 200L)
            } catch (e: RuntimeException) {
                // No tone generator (audio busy): the screen still shows the state.
            }
        }
    }
}
