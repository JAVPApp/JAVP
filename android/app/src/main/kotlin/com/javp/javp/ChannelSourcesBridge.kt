package com.javp.javp

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Dart bridge for [SharedSourcesProvider] — publish local sources and pull a
 * newer snapshot from the sibling Stable/Dev package when installed.
 */
class ChannelSourcesBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)

    init {
        SharedSourcesProvider.registerAuthority(context.packageName)
        channel.setMethodCallHandler(this)
    }

    fun detach() {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(true)
            "publish" -> {
                val payload = call.argument<String>("payload")
                if (payload.isNullOrBlank()) {
                    result.error("bad_args", "payload required", null)
                    return
                }
                result.success(publish(payload))
            }
            "pullSibling" -> result.success(pullSibling())
            else -> result.notImplemented()
        }
    }

    private fun publish(payload: String): Boolean {
        return try {
            SharedSourcesProvider.writePayload(context, payload)
            val sibling = SharedSourcesProvider.siblingPackage(context.packageName)
            if (sibling != null &&
                SharedSourcesProvider.isPackageInstalled(context, sibling)
            ) {
                val values = ContentValues().apply {
                    put(SharedSourcesProvider.COLUMN_PAYLOAD, payload)
                }
                val uri = SharedSourcesProvider.sourcesUri(sibling)
                val updated = context.contentResolver.update(uri, values, null, null)
                if (updated <= 0) {
                    context.contentResolver.insert(uri, values)
                }
            }
            true
        } catch (_: Exception) {
            // Sibling missing permission / not installed — local write still done.
            true
        }
    }

    private fun pullSibling(): String? {
        val sibling = SharedSourcesProvider.siblingPackage(context.packageName)
            ?: return null
        if (!SharedSourcesProvider.isPackageInstalled(context, sibling)) {
            return null
        }
        var cursor: Cursor? = null
        return try {
            cursor = context.contentResolver.query(
                SharedSourcesProvider.sourcesUri(sibling),
                arrayOf(SharedSourcesProvider.COLUMN_PAYLOAD),
                null,
                null,
                null,
            )
            if (cursor != null && cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(SharedSourcesProvider.COLUMN_PAYLOAD)
                if (idx >= 0) cursor.getString(idx) else null
            } else {
                null
            }
        } catch (_: Exception) {
            null
        } finally {
            cursor?.close()
        }
    }

    companion object {
        private const val CHANNEL = "javp/channel_sources"
    }
}
