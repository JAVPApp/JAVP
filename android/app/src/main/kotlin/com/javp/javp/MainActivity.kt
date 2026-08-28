package com.javp.javp

import android.app.ActivityManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.app.UiModeManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pipChannel: MethodChannel? = null
    private var browserChannel: MethodChannel? = null
    private var externalPlayerChannel: MethodChannel? = null
    private var deepLinkChannel: MethodChannel? = null
    private var tvPlatformChannel: MethodChannel? = null
    private var chromecastBridge: ChromecastBridge? = null
    private var lanMulticastLock: LanMulticastLock? = null
    private var channelSourcesBridge: ChannelSourcesBridge? = null
    private var downloadKeepAliveBridge: DownloadKeepAliveBridge? = null
    private var autoEnter = false
    private var aspectX = 16
    private var aspectY = 9
    private var playing = false
    private var receiverRegistered = false

    private val actionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.getIntExtra(EXTRA_CONTROL_TYPE, 0)) {
                CONTROL_PLAY -> pipChannel?.invokeMethod("onPipAction", "play")
                CONTROL_PAUSE -> pipChannel?.invokeMethod("onPipAction", "pause")
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pipChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(isPipSupported())
                    "isInPip" -> result.success(isInPipMode())
                    "enter" -> {
                        val args = call.arguments as? Map<*, *>
                        applyArgs(args)
                        result.success(enterPip())
                    }
                    "setAutoEnter" -> {
                        val args = call.arguments as? Map<*, *>
                        applyArgs(args)
                        autoEnter = args?.get("enabled") as? Boolean ?: false
                        updatePipParams()
                        result.success(null)
                    }
                    "setPlaying" -> {
                        playing = call.argument<Boolean>("playing") ?: false
                        updatePipParams()
                        result.success(null)
                    }
                    "setAspectRatio" -> {
                        aspectX = (call.argument<Number>("aspectX")?.toInt() ?: 16)
                            .coerceAtLeast(1)
                        aspectY = (call.argument<Number>("aspectY")?.toInt() ?: 9)
                            .coerceAtLeast(1)
                        updatePipParams()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        browserChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BROWSER_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "openInBrowser" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.error("bad_args", "url required", null)
                            return@setMethodCallHandler
                        }
                        result.success(openInBrowser(url))
                    }
                    else -> result.notImplemented()
                }
            }
        }
        externalPlayerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EXTERNAL_PLAYER_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "openMedia" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.error("bad_args", "url required", null)
                            return@setMethodCallHandler
                        }
                        val title = call.argument<String>("title")
                        val mime = call.argument<String>("mime") ?: "video/*"
                        result.success(openInExternalPlayer(url, title, mime))
                    }
                    else -> result.notImplemented()
                }
            }
        }
        deepLinkChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEEP_LINK_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialLink" -> result.success(intent?.data?.toString())
                    else -> result.notImplemented()
                }
            }
        }
        tvPlatformChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TV_PLATFORM_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAndroidTv" -> result.success(isAndroidTvDevice())
                    "isEmulator" -> result.success(isEmulatorDevice())
                    "memoryClassMb" -> result.success(memoryClassMb())
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DISPLAY_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getBrightness" -> {
                    val value = window.attributes.screenBrightness
                    result.success(value.toDouble())
                }
                "setBrightness" -> {
                    val raw = call.argument<Number>("value")?.toFloat() ?: -1f
                    val lp = window.attributes
                    lp.screenBrightness = if (raw < 0f) -1f else raw.coerceIn(0f, 1f)
                    window.attributes = lp
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        registerActionReceiver()
        chromecastBridge = ChromecastBridge(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        lanMulticastLock = LanMulticastLock(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        channelSourcesBridge = ChannelSourcesBridge(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        downloadKeepAliveBridge = DownloadKeepAliveBridge(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
    }

    private fun isAndroidTvDevice(): Boolean {
        val uiMode = getSystemService(UI_MODE_SERVICE) as? UiModeManager
        if (uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) {
            return true
        }
        return packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            packageManager.hasSystemFeature("android.software.leanback")
    }

    private fun isEmulatorDevice(): Boolean {
        val fingerprint = Build.FINGERPRINT.lowercase()
        val model = Build.MODEL.lowercase()
        val product = Build.PRODUCT.lowercase()
        val hardware = Build.HARDWARE.lowercase()
        val manufacturer = Build.MANUFACTURER.lowercase()
        return fingerprint.contains("generic") ||
            fingerprint.contains("emulator") ||
            fingerprint.contains("unknown") ||
            model.contains("google_sdk") ||
            model.contains("emulator") ||
            model.contains("android sdk built for") ||
            product.contains("sdk") ||
            product.contains("emulator") ||
            product.contains("vbox") ||
            hardware.contains("goldfish") ||
            hardware.contains("ranchu") ||
            manufacturer.contains("genymotion")
    }

    /** Per-app heap class in MB (ActivityManager.memoryClass), for image-cache sizing. */
    private fun memoryClassMb(): Int {
        val am = getSystemService(ACTIVITY_SERVICE) as? ActivityManager
        return am?.memoryClass ?: 0
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Warm VIEW intents (e.g. javp://add while already on Welcome) never
        // reach Dart via defaultRouteName — forward them explicitly.
        val link = intent.data?.toString()
        if (!link.isNullOrBlank()) {
            deepLinkChannel?.invokeMethod("onLink", link)
        }
    }

    /**
     * Opens [url] in a real browser package so App Links cannot hand
     * `app.plex.tv` / `plex.tv` over to the Plex Android app.
     */
    private fun openInBrowser(url: String): Boolean {
        val uri = try {
            Uri.parse(url)
        } catch (_: Exception) {
            return false
        }
        val browserPackage = resolveBrowserPackage()
        val intent = Intent(Intent.ACTION_VIEW, uri).apply {
            addCategory(Intent.CATEGORY_BROWSABLE)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (browserPackage != null) {
                setPackage(browserPackage)
            }
        }
        return try {
            startActivity(intent)
            true
        } catch (_: Exception) {
            if (browserPackage == null) return false
            // Retry without a forced package (chooser / fallback).
            return try {
                startActivity(
                    Intent(Intent.ACTION_VIEW, uri)
                        .addCategory(Intent.CATEGORY_BROWSABLE)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    /**
     * Opens [url] in an external media player via the system chooser so the
     * user picks the app instead of always landing in VLC.
     */
    private fun openInExternalPlayer(url: String, title: String?, mime: String): Boolean {
        val uri = try {
            Uri.parse(url)
        } catch (_: Exception) {
            return false
        }
        fun buildIntent(): Intent {
            return Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                if (!title.isNullOrBlank()) {
                    putExtra(Intent.EXTRA_TITLE, title)
                }
                putExtra("title", title)
                putExtra("android.intent.extra.TITLE", title)
            }
        }

        val view = buildIntent()
        val chooserTitle = title?.takeIf { it.isNotBlank() }
        return try {
            startActivity(Intent.createChooser(view, chooserTitle))
            true
        } catch (_: Exception) {
            try {
                startActivity(view)
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    private fun resolveBrowserPackage(): String? {
        val probe = Intent(Intent.ACTION_VIEW, Uri.parse("https://example.com"))
            .addCategory(Intent.CATEGORY_BROWSABLE)
        val default = packageManager.resolveActivity(
            probe,
            PackageManager.MATCH_DEFAULT_ONLY,
        )?.activityInfo?.packageName
        if (default != null && !isPlexPackage(default)) {
            return default
        }
        for (candidate in listOf(
            "com.android.chrome",
            "com.chrome.beta",
            "com.chrome.dev",
            "com.microsoft.emmx",
            "org.mozilla.firefox",
            "com.brave.browser",
            "com.opera.browser",
            "com.sec.android.app.sbrowser",
        )) {
            if (isPackageInstalled(candidate) && !isPlexPackage(candidate)) {
                return candidate
            }
        }
        return null
    }

    private fun isPackageInstalled(packageName: String): Boolean {
        return try {
            packageManager.getPackageInfo(packageName, 0)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun isPlexPackage(packageName: String): Boolean {
        val lower = packageName.lowercase()
        return lower.contains("plex")
    }

    override fun onDestroy() {
        chromecastBridge?.detach()
        chromecastBridge = null
        lanMulticastLock?.detach()
        lanMulticastLock = null
        channelSourcesBridge?.detach()
        channelSourcesBridge = null
        downloadKeepAliveBridge?.detach()
        downloadKeepAliveBridge = null
        if (receiverRegistered) {
            try {
                unregisterReceiver(actionReceiver)
            } catch (_: Exception) {
            }
            receiverRegistered = false
        }
        pipChannel = null
        browserChannel = null
        deepLinkChannel = null
        tvPlatformChannel = null
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 8–11 has no setAutoEnterEnabled; enter explicitly.
        // Android 12+ must use setAutoEnterEnabled / onPictureInPictureRequested
        // so share sheets and other overlays do not trigger PiP.
        if (autoEnter &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S &&
            !isInPipMode()
        ) {
            enterPip()
        }
    }

    override fun onPictureInPictureRequested(): Boolean {
        if (autoEnter && enterPip()) return true
        return super.onPictureInPictureRequested()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("onPipChanged", isInPictureInPictureMode)
    }

    @Deprecated("Deprecated in Java")
    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean) {
        @Suppress("DEPRECATION")
        super.onPictureInPictureModeChanged(isInPictureInPictureMode)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            pipChannel?.invokeMethod("onPipChanged", isInPictureInPictureMode)
        }
    }

    private fun applyArgs(args: Map<*, *>?) {
        if (args == null) return
        (args["aspectX"] as? Number)?.toInt()?.let { aspectX = it.coerceAtLeast(1) }
        (args["aspectY"] as? Number)?.toInt()?.let { aspectY = it.coerceAtLeast(1) }
        (args["playing"] as? Boolean)?.let { playing = it }
    }

    private fun isPipSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        // Leanback / Android TV uses a different overlay; activity PiP is a no-op.
        if (isAndroidTvDevice()) return false
        // Do not require FEATURE_PICTURE_IN_PICTURE — several OEM builds omit it.
        return true
    }

    private fun isInPipMode(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        return isInPictureInPictureMode
    }

    private fun enterPip(): Boolean {
        if (!isPipSupported()) return false
        if (isInPipMode()) {
            notifyPipChanged(true)
            return true
        }
        return try {
            val entered = enterPictureInPictureMode(buildPipParams())
            if (entered) notifyPipChanged(true)
            entered
        } catch (_: Exception) {
            false
        }
    }

    private fun notifyPipChanged(active: Boolean) {
        pipChannel?.invokeMethod("onPipChanged", active)
    }

    private fun updatePipParams() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            setPictureInPictureParams(buildPipParams())
        } catch (_: Exception) {
        }
    }

    private fun buildPipParams(): PictureInPictureParams {
        val ratio = clampedAspectRatio(aspectX, aspectY)
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(ratio)
            .setActions(listOf(if (playing) pauseAction() else playAction()))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(autoEnter)
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    private fun playAction(): RemoteAction {
        return RemoteAction(
            Icon.createWithResource(this, android.R.drawable.ic_media_play),
            "Play",
            "Play",
            mediaPendingIntent(CONTROL_PLAY),
        )
    }

    private fun pauseAction(): RemoteAction {
        return RemoteAction(
            Icon.createWithResource(this, android.R.drawable.ic_media_pause),
            "Pause",
            "Pause",
            mediaPendingIntent(CONTROL_PAUSE),
        )
    }

    /**
     * PiP RemoteAction transport only — not a mediaPlayback foreground service.
     * Play Console sometimes attributes Android 15 FGS+BOOT_COMPLETED findings
     * here; boot work stays in flutter_local_notifications' reschedule path.
     */
    private fun mediaPendingIntent(controlType: Int): PendingIntent {
        val intent = Intent(ACTION_MEDIA_CONTROL).setPackage(packageName)
            .putExtra(EXTRA_CONTROL_TYPE, controlType)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        return PendingIntent.getBroadcast(this, controlType, intent, flags)
    }

    private fun registerActionReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter(ACTION_MEDIA_CONTROL)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(actionReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(actionReceiver, filter)
        }
        receiverRegistered = true
    }

    companion object {
        private const val CHANNEL = "javp/pip"
        private const val BROWSER_CHANNEL = "javp/browser"
        private const val EXTERNAL_PLAYER_CHANNEL = "javp/external_player"
        private const val DEEP_LINK_CHANNEL = "javp/deep_links"
        private const val TV_PLATFORM_CHANNEL = "javp/tv_platform"
        private const val DISPLAY_CHANNEL = "javp/display"
        private const val ACTION_MEDIA_CONTROL = "com.javp.javp.PIP_MEDIA_CONTROL"
        private const val EXTRA_CONTROL_TYPE = "control_type"
        private const val CONTROL_PLAY = 1
        private const val CONTROL_PAUSE = 2

        /** Android PiP rejects ratios outside ~2.39:1 .. 1:2.39. */
        private fun clampedAspectRatio(x: Int, y: Int): Rational {
            val ax = x.coerceAtLeast(1).toDouble()
            val ay = y.coerceAtLeast(1).toDouble()
            var ratio = ax / ay
            val max = 2.39
            val min = 1.0 / 2.39
            if (ratio > max) ratio = max
            if (ratio < min) ratio = min
            val num = (ratio * 1000).toInt().coerceAtLeast(1)
            return Rational(num, 1000)
        }
    }
}
