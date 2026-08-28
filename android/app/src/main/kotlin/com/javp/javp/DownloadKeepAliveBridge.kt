package com.javp.javp

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Dart bridge for [DownloadKeepAliveService]. */
class DownloadKeepAliveBridge(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val appContext = context.applicationContext
    private val channel = MethodChannel(messenger, CHANNEL)

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val title = call.argument<String>("title") ?: "Downloads"
                val text = call.argument<String>("text") ?: ""
                val progress = call.argument<Int>("progress") ?: 0
                val indeterminate = call.argument<Boolean>("indeterminate") ?: true
                try {
                    DownloadKeepAliveService.start(
                        appContext,
                        title,
                        text,
                        progress,
                        indeterminate,
                    )
                    result.success(null)
                } catch (e: Exception) {
                    result.error("start_failed", e.message, null)
                }
            }
            "stop" -> {
                try {
                    DownloadKeepAliveService.stop(appContext)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("stop_failed", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    fun detach() {
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL = "javp/download_keepalive"
    }
}
