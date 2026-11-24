package com.livekit.example.VoiceAssistantFlutter

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import java.security.MessageDigest

class UpdatesBridge(private val activity: MainActivity) {
    @Suppress("DEPRECATION")
    fun version(): Long {
        val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
        return if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    }

    @Suppress("DEPRECATION")
    fun install(token: String, expected: String, result: MethodChannel.Result) {
        if (!expected.matches(Regex("[a-f0-9]{64}")) || !token.startsWith("jd1.")) {
            result.error("invalid_update", "Atualização inválida.", null); return
        }
        Thread {
            try {
                val dir = File(activity.cacheDir, "updates").apply { mkdirs() }
                val file = File(dir, "jarvis-primary.apk")
                val partial = File(dir, "download.tmp")
                val connection = URL("https://your-jarvis-api.example.com/v1/updates/package").openConnection() as HttpsURLConnection
                connection.instanceFollowRedirects = false
                connection.connectTimeout = 15000; connection.readTimeout = 90000
                connection.setRequestProperty("Authorization", "Bearer $token")
                val digest = MessageDigest.getInstance("SHA-256")
                try {
                    check(connection.responseCode == 200) { "Download recusado pelo servidor." }
                    connection.inputStream.use { input -> partial.outputStream().use { output ->
                        val buffer = ByteArray(65536); var total = 0L
                        while (true) {
                            val count = input.read(buffer); if (count < 0) break
                            total += count; check(total <= 1073741824L) { "Pacote excede o limite." }
                            digest.update(buffer, 0, count); output.write(buffer, 0, count)
                        }
                    } }
                } finally { connection.disconnect() }
                check(digest.digest().joinToString("") { "%02x".format(it) } == expected) { "Hash do pacote não confere." }
                val flags = PackageManager.GET_SIGNATURES
                val current = activity.packageManager.getPackageInfo(activity.packageName, flags)
                val archive = activity.packageManager.getPackageArchiveInfo(partial.path, flags) ?: error("APK inválido.")
                check(archive.packageName == activity.packageName && archive.signatures?.toSet() == current.signatures?.toSet()) { "Assinatura incompatível." }
                val next = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else archive.versionCode.toLong()
                check(next > version()) { "Esta versão já está instalada." }
                check(partial.renameTo(file)) { "Não foi possível preparar o pacote." }
                activity.runOnUiThread {
                    try {
                        if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
                            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
                            result.success("Autorize a instalação pelo Jarvis e toque novamente em Atualizar.")
                        } else {
                            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
                            activity.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                            result.success("Confirme a instalação na tela do Android.")
                        }
                    } catch (e: Exception) { result.error("install", "Não foi possível abrir o instalador Android.", null) }
                }
            } catch (e: Exception) { activity.runOnUiThread { result.error("update", e.message ?: "Atualização falhou.", null) } }
        }.start()
    }
}
