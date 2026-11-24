package com.livekit.example.VoiceAssistantFlutter

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel

// Hands events from the service and the notification listener to the Flutter side
// (lib/master/master_platform.dart). Messages that Flutter cannot take right now
// are kept by SocialStore and collected when it starts.
object MasterBridge {
    private const val TAG = "MasterBridge"
    private val main = Handler(Looper.getMainLooper())

    @Volatile var channel: MethodChannel? = null

    fun serviceAction(action: String) {
        main.post { channel?.invokeMethod("serviceAction", action) }
    }

    // Returns at once; on failure the message is queued for the next start.
    fun socialPosted(context: android.content.Context, message: Map<String, Any?>) {
        val target = channel
        if (target == null) {
            Log.i(TAG, "Flutter not running: message kept for later")
            SocialStore.addPending(context, message)
            return
        }
        main.post {
            target.invokeMethod("socialPosted", message, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (result != true) SocialStore.addPending(context, message)
                }

                override fun error(code: String, msg: String?, details: Any?) {
                    Log.w(TAG, "Flutter refused a message: $code $msg")
                    SocialStore.addPending(context, message)
                }

                override fun notImplemented() {
                    SocialStore.addPending(context, message)
                }
            })
        }
    }
}
