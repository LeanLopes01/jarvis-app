package com.livekit.example.VoiceAssistantFlutter

import android.app.Notification
import android.app.Person
import android.os.Build
import android.os.Bundle
import android.os.Parcelable
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

// Reads the WhatsApp and Instagram message notifications this phone receives, after
// the user allows notification access. Android gives the listener every app's
// notifications: anything that is not from these two packages is dropped here,
// before it is stored or sent anywhere.
class SocialListener : NotificationListenerService() {
    // Android only delivers notifications posted after the listener connects: read
    // the messages still in the shade (still unread) once, when it connects.
    override fun onListenerConnected() {
        super.onListenerConnected()
        connected = this
        Log.i(TAG, "listener connected")
        val shown = try { activeNotifications } catch (e: Exception) { null } ?: return
        for (sbn in shown) handle(sbn, CONNECT_MAX_AGE_MS)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) = handle(sbn, MAX_AGE_MS)

    override fun onListenerDisconnected() {
        connected = null
        super.onListenerDisconnected()
        requestRebind(android.content.ComponentName(this, SocialListener::class.java))
    }

    private fun replayActive() {
        val shown = try { activeNotifications } catch (e: Exception) { null } ?: return
        for (sbn in shown) handle(sbn, CONNECT_MAX_AGE_MS, replay = true)
    }

    private fun handle(sbn: StatusBarNotification, maxAge: Long, replay: Boolean = false) {
        if (MainActivity.isCompanion(this)) return
        val app = APPS[sbn.packageName] ?: return
        val notification = sbn.notification ?: return
        val channelId = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) notification.channelId else null
        SocialStore.observe(this, app, channelId, notification.category)

        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (notification.flags and Notification.FLAG_ONGOING_EVENT != 0) return // calls, backups
        val extras = notification.extras ?: return
        val messages = extras.getParcelableArray(Notification.EXTRA_MESSAGES)
        if (!isMessage(notification, channelId, messages)) return

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val conversation = extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()
            ?.let { cleanTitle(it) }
        val cutoff = System.currentTimeMillis() - maxAge

        if (messages != null && messages.isNotEmpty()) {
            // MessagingStyle: one bundle per message, older unread ones included.
            for (item in messages) {
                val bundle = item as? Bundle ?: continue
                val text = bundle.getCharSequence("text")?.toString()
                val time = bundle.getLong("time", sbn.postTime)
                val sender = senderOf(bundle) ?: continue // no sender: the user's own reply
                if (time < cutoff) continue
                emit(app, sbn.key, sender, conversation, text, time, stamp = time, replay = replay)
            }
        } else {
            val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
            if (title.isNullOrBlank() || title.equals(APP_NAMES[app], ignoreCase = true)) return
            if (text != null && SUMMARY.matches(text.trim())) return // "3 new messages"
            val (sender, group) = splitTitle(title)
            // No per-message time here: an update of the same text is not a new message.
            emit(app, sbn.key, sender, conversation ?: group, text, sbn.postTime, stamp = 0L, replay = replay)
        }
    }

    private fun emit(
        app: String, key: String, sender: String, conversation: String?, text: String?, time: Long, stamp: Long,
        replay: Boolean = false,
    ) {
        val visible = text?.takeUnless { it.isBlank() || HIDDEN.matches(it.trim()) }
        val id = "$app:${(key + stamp + sender + (visible ?: "")).hashCode()}"
        if (!SocialStore.markSeen(this, id) && !replay) return
        // Flutter deduplicates replays by key, including messages already read.
        Log.i(TAG, "message from $app (${if (visible == null) "content hidden" else "with text"})")
        MasterBridge.socialPosted(
            this,
            mapOf(
                "key" to id,
                "app" to app,
                "sender" to sender,
                "conversation" to conversation?.takeIf { it != sender },
                "text" to visible,
                "posted_at" to time / 1000.0,
            ),
        )
    }

    companion object {
        private var connected: SocialListener? = null

        fun refresh(context: android.content.Context) {
            val listener = connected
            if (listener != null) listener.replayActive()
            else if (MainActivity.hasNotificationAccess(context)) {
                requestRebind(android.content.ComponentName(context, SocialListener::class.java))
            }
        }

        private val APPS = mapOf("com.whatsapp" to "whatsapp", "com.instagram.android" to "instagram")
        private val APP_NAMES = mapOf("whatsapp" to "WhatsApp", "instagram" to "Instagram")
        private const val TAG = "SocialListener"
        private const val MAX_AGE_MS = 10 * 60 * 1000L // older messages in a bundle are not news
        private const val CONNECT_MAX_AGE_MS = 12 * 60 * 60 * 1000L // still in the shade: unread
        private val SUMMARY = Regex("""^\d+ (new )?(messages?|mensagens?( novas)?)( from \d+ chats)?\.?$""", RegexOption.IGNORE_CASE)
        private val HIDDEN = Regex("""^(new message|nova mensagem|\d+ new messages?)\.?$""", RegexOption.IGNORE_CASE)
        private val COUNT_SUFFIX = Regex("""\s*\(\d+ (messages?|mensagens?)\)\s*$""", RegexOption.IGNORE_CASE)

        // Messages only: no likes, suggestions, lives, backups or service alerts.
        private fun isMessage(notification: Notification, channelId: String?, messages: Array<Parcelable>?): Boolean {
            if (messages != null) return true
            if (notification.category == Notification.CATEGORY_MESSAGE) return true
            val channel = channelId?.lowercase() ?: return false
            return listOf("direct", "message", "chat", "dm").any { channel.contains(it) }
        }

        private fun senderOf(bundle: Bundle): String? {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                @Suppress("DEPRECATION")
                val person = bundle.getParcelable<Person>("sender_person")
                person?.name?.toString()?.let { return it }
            }
            return bundle.getCharSequence("sender")?.toString()
        }

        private fun cleanTitle(title: String) = title.replace(COUNT_SUFFIX, "").trim()

        // WhatsApp groups without MessagingStyle: "Group: Sender".
        private fun splitTitle(title: String): Pair<String, String?> {
            val clean = cleanTitle(title)
            val colon = clean.indexOf(": ")
            return if (colon > 0) clean.substring(colon + 2) to clean.substring(0, colon) else clean to null
        }
    }
}
