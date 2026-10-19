package com.voiceagent.voice_agent

import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// The 'voiceagent/files' channel: OPEN(path, mime) hands a received
/// file to the system viewer — for an APK that is the package
/// installer, which is the whole point of the self-update loop. The
/// URI rides a FileProvider (a bare file:// Uri throws
/// FileUriExposedException since API 24) with a read grant, so the
/// installer can read exactly this one file. Any other type opens in
/// whatever app claims it; nothing to claim it, and the error rides
/// back to the bubble's status line.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "voiceagent/files",
        ).setMethodCallHandler { call, result ->
            if (call.method != "open") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path") ?: ""
            val mime = call.argument<String>("mime") ?: "*/*"
            val f = File(path)
            if (!f.exists()) {
                result.error("missing", "no file at $path", null)
                return@setMethodCallHandler
            }
            try {
                val uri = FileProvider.getUriForFile(
                    this, "$packageName.fileprovider", f,
                )
                startActivity(
                    Intent(Intent.ACTION_VIEW)
                        .setDataAndType(uri, mime)
                        .addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_ACTIVITY_NEW_TASK,
                        ),
                )
                result.success(true)
            } catch (e: Exception) {
                result.error("open", e.message, null)
            }
        }
    }
}
