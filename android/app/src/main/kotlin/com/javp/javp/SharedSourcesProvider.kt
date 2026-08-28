package com.javp.javp

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.UriMatcher
import android.content.pm.PackageManager
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Binder
import android.os.ParcelFileDescriptor
import android.os.Process
import java.io.File
import java.nio.charset.StandardCharsets

/**
 * Signature-protected Stable ↔ Dev sources mirror.
 *
 * Each channel hosts `content://{applicationId}.shared_sources/sources`.
 * Access is enforced with [PackageManager.checkSignatures] (same upload key),
 * not a shared `<permission>` name — declaring the same custom permission from
 * both packages causes INSTALL_FAILED_DUPLICATE_PERMISSION when the second
 * channel is installed (Fire TV PackageInstaller only shows "OK").
 *
 * Payload is opaque UTF-8 JSON from Dart (may include source passwords — same
 * trust model as Windows sharing one AppData folder between Stable and Dev).
 */
class SharedSourcesProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        val pkg = context?.packageName
        if (pkg != null) {
            registerAuthority(pkg)
        }
        return true
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        if (matcher.match(uri) != CODE_SOURCES) return null
        val ctx = context ?: return null
        enforceSameSignature(ctx)
        val payload = readPayload(ctx)
        val cursor = MatrixCursor(arrayOf(COLUMN_PAYLOAD))
        cursor.addRow(arrayOf(payload))
        return cursor
    }

    override fun getType(uri: Uri): String? {
        return if (matcher.match(uri) == CODE_SOURCES) {
            "vnd.android.cursor.item/vnd.javp.shared_sources"
        } else {
            null
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? {
        if (matcher.match(uri) != CODE_SOURCES) return null
        val ctx = context ?: return null
        enforceSameSignature(ctx)
        val payload = values?.getAsString(COLUMN_PAYLOAD) ?: return null
        writePayload(ctx, payload)
        ctx.contentResolver.notifyChange(uri, null)
        return uri
    }

    override fun delete(
        uri: Uri,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int {
        if (matcher.match(uri) != CODE_SOURCES) return 0
        val ctx = context ?: return 0
        enforceSameSignature(ctx)
        val file = payloadFile(ctx)
        return if (file.exists() && file.delete()) 1 else 0
    }

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int {
        if (matcher.match(uri) != CODE_SOURCES) return 0
        val ctx = context ?: return 0
        enforceSameSignature(ctx)
        val payload = values?.getAsString(COLUMN_PAYLOAD) ?: return 0
        writePayload(ctx, payload)
        ctx.contentResolver.notifyChange(uri, null)
        return 1
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        return null
    }

    private fun enforceSameSignature(ctx: Context) {
        val callingUid = Binder.getCallingUid()
        if (callingUid == Process.myUid()) return
        val result = ctx.packageManager.checkSignatures(Process.myUid(), callingUid)
        if (result != PackageManager.SIGNATURE_MATCH) {
            throw SecurityException("SharedSourcesProvider: caller is not same-signer")
        }
    }

    companion object {
        const val COLUMN_PAYLOAD = "payload"
        private const val CODE_SOURCES = 1
        private const val FILE_NAME = "channel_shared_sources.json"

        private val matcher = UriMatcher(UriMatcher.NO_MATCH)
        private val registeredAuthorities = mutableSetOf<String>()

        fun authorityFor(packageName: String): String =
            "$packageName.shared_sources"

        fun sourcesUri(packageName: String): Uri =
            Uri.parse("content://${authorityFor(packageName)}/sources")

        fun registerAuthority(packageName: String) {
            val authority = authorityFor(packageName)
            if (registeredAuthorities.add(authority)) {
                matcher.addURI(authority, "sources", CODE_SOURCES)
            }
        }

        fun siblingPackage(packageName: String): String? = when {
            packageName.endsWith(".dev") -> packageName.removeSuffix(".dev")
            else -> "$packageName.dev"
        }

        fun isPackageInstalled(context: Context, packageName: String): Boolean {
            return try {
                context.packageManager.getPackageInfo(packageName, 0)
                true
            } catch (_: PackageManager.NameNotFoundException) {
                false
            }
        }

        fun readPayload(context: Context): String {
            val file = payloadFile(context)
            if (!file.exists()) return ""
            return try {
                file.readText(StandardCharsets.UTF_8)
            } catch (_: Exception) {
                ""
            }
        }

        fun writePayload(context: Context, payload: String) {
            val file = payloadFile(context)
            file.parentFile?.mkdirs()
            file.writeText(payload, StandardCharsets.UTF_8)
        }

        private fun payloadFile(context: Context): File =
            File(context.filesDir, FILE_NAME)
    }
}
