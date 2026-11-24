package com.livekit.example.VoiceAssistantFlutter

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

// Small private store for the notification listener: which messages were already
// passed on, messages waiting for the Flutter side, and per-channel counts (no
// content) that show how WhatsApp and Instagram label their notifications.
object SocialStore {
    private const val FILE = "jarvis_social"
    private const val SEEN_LIMIT = 500
    private const val PENDING_LIMIT = 100

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    @Synchronized
    fun markSeen(context: Context, id: String): Boolean {
        val prefs = prefs(context)
        val seen = JSONArray(prefs.getString("seen", "[]"))
        for (i in 0 until seen.length()) if (seen.getString(i) == id) return false
        seen.put(id)
        val trimmed = JSONArray()
        for (i in maxOf(0, seen.length() - SEEN_LIMIT) until seen.length()) trimmed.put(seen.getString(i))
        prefs.edit().putString("seen", trimmed.toString()).apply()
        return true
    }

    @Synchronized
    fun addPending(context: Context, message: Map<String, Any?>) {
        val prefs = prefs(context)
        val pending = JSONArray(prefs.getString("pending", "[]"))
        pending.put(JSONObject(message))
        val trimmed = JSONArray()
        for (i in maxOf(0, pending.length() - PENDING_LIMIT) until pending.length()) trimmed.put(pending.get(i))
        prefs.edit().putString("pending", trimmed.toString()).apply()
    }

    @Synchronized
    fun drain(context: Context): List<Map<String, Any?>> {
        val prefs = prefs(context)
        val pending = JSONArray(prefs.getString("pending", "[]"))
        prefs.edit().putString("pending", "[]").apply()
        return (0 until pending.length()).map { toMap(pending.getJSONObject(it)) }
    }

    @Synchronized
    fun observe(context: Context, app: String, channel: String?, category: String?) {
        val prefs = prefs(context)
        val stats = JSONObject(prefs.getString("channels", "{}"))
        val key = "$app|${channel ?: "-"}|${category ?: "-"}"
        stats.put(key, stats.optInt(key, 0) + 1)
        prefs.edit().putString("channels", stats.toString()).apply()
    }

    fun channels(context: Context): List<Map<String, Any?>> {
        val stats = JSONObject(prefs(context).getString("channels", "{}"))
        return stats.keys().asSequence().map { key ->
            val (app, channel, category) = key.split("|", limit = 3)
            mapOf("app" to app, "channel" to channel, "category" to category, "count" to stats.getInt(key))
        }.toList()
    }

    private fun toMap(json: JSONObject): Map<String, Any?> =
        json.keys().asSequence().associateWith { key -> json.get(key).takeUnless { it == JSONObject.NULL } }
}
