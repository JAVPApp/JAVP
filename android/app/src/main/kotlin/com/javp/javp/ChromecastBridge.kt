package com.javp.javp

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.ContextThemeWrapper
import androidx.mediarouter.app.MediaRouteChooserDialog
import androidx.mediarouter.media.MediaRouteSelector
import androidx.mediarouter.media.MediaRouter
import android.util.Log
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.HlsSegmentFormat
import com.google.android.gms.cast.HlsVideoSegmentFormat
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadOptions
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaSeekOptions
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import com.google.android.gms.common.api.ResultCallback
import com.google.android.gms.common.images.WebImage
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Method channel bridge for [javp/chromecast].
 *
 * Dart methods: loadMedia, stop, startDiscovery, stopDiscovery, listDevices.
 * Native → Dart: onSessionStarted, onSessionEnded, onCastDevices.
 */
class ChromecastBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val castExecutor = Executors.newSingleThreadExecutor()

    private var castContext: CastContext? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingMedia: PendingMedia? = null
    private var chooserDialog: MediaRouteChooserDialog? = null
    private var sessionListenerRegistered = false
    private var awaitingSessionForLoad = false
    private var routerCallbackRegistered = false
    private var mediaCallback: RemoteMediaClient.Callback? = null
    private var pendingSeekMs: Long = -1L
    private var lastStatusEmitAt = 0L

    private val routerCallback = object : MediaRouter.Callback() {
        override fun onRouteAdded(router: MediaRouter, route: MediaRouter.RouteInfo) {
            emitDevices()
        }

        override fun onRouteRemoved(router: MediaRouter, route: MediaRouter.RouteInfo) {
            emitDevices()
        }

        override fun onRouteChanged(router: MediaRouter, route: MediaRouter.RouteInfo) {
            emitDevices()
        }
    }

    private val sessionListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarting(session: CastSession) {}

        override fun onSessionStarted(session: CastSession, sessionId: String) {
            channel.invokeMethod(
                "onSessionStarted",
                session.castDevice?.friendlyName,
            )
            emitVolume(session)
            if (awaitingSessionForLoad) {
                awaitingSessionForLoad = false
                val media = pendingMedia
                if (media != null) {
                    loadOntoSession(session, media, completePending = true)
                } else {
                    completePending(true)
                }
            }
        }

        override fun onSessionStartFailed(session: CastSession, error: Int) {
            if (awaitingSessionForLoad) {
                awaitingSessionForLoad = false
                completePending(false)
            }
        }

        override fun onSessionEnding(session: CastSession) {}

        override fun onSessionEnded(session: CastSession, error: Int) {
            channel.invokeMethod("onSessionEnded", null)
        }

        override fun onSessionResuming(session: CastSession, sessionId: String) {}

        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) {
            channel.invokeMethod(
                "onSessionStarted",
                session.castDevice?.friendlyName,
            )
            emitVolume(session)
        }

        override fun onSessionResumeFailed(session: CastSession, error: Int) {}

        override fun onSessionSuspended(session: CastSession, reason: Int) {}
    }

    init {
        channel.setMethodCallHandler(this)
        ensureCastContext { /* warm up discovery */ }
    }

    fun detach() {
        dismissChooser()
        pendingResult?.success(false)
        pendingResult = null
        pendingMedia = null
        awaitingSessionForLoad = false
        stopDiscovery()
        castContext?.sessionManager?.removeSessionManagerListener(
            sessionListener,
            CastSession::class.java,
        )
        sessionListenerRegistered = false
        channel.setMethodCallHandler(null)
        castExecutor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadMedia" -> handleLoadMedia(call, result)
            "stop" -> handleStop(result)
            "play" -> handleTransport("play", result)
            "pause" -> handleTransport("pause", result)
            "seek" -> handleSeek(call, result)
            "setPlaybackRate" -> handleSetPlaybackRate(call, result)
            "setVolume" -> handleSetVolume(call, result)
            "getVolume" -> handleGetVolume(result)
            "startDiscovery" -> {
                // Cast routes only appear after CastContext is up — never register
                // the MediaRouter callback before that or the list stays empty.
                ensureCastContext { ctx ->
                    if (ctx != null) {
                        registerSessionListener(ctx)
                        startDiscovery()
                    }
                    result.success(currentDevices())
                }
            }
            "stopDiscovery" -> {
                stopDiscovery()
                result.success(null)
            }
            "listDevices" -> {
                ensureCastContext {
                    result.success(currentDevices())
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun handleLoadMedia(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.success(false)
            return
        }
        val media = PendingMedia(
            url = url,
            title = call.argument<String>("title") ?: "JAVP",
            subtitle = call.argument<String>("subtitle"),
            posterUrl = call.argument<String>("posterUrl"),
            positionMs = (call.argument<Number>("positionMs")?.toLong() ?: 0L).coerceAtLeast(0L),
            live = call.argument<Boolean>("live") == true,
            contentType = call.argument<String>("contentType"),
            deferSeek = call.argument<Boolean>("deferSeek") == true,
            hlsSegmentFormat = call.argument<String>("hlsSegmentFormat"),
        )

        pendingResult?.success(false)
        pendingResult = result
        pendingMedia = media
        awaitingSessionForLoad = false
        val routeId = call.argument<String>("routeId")

        ensureCastContext { ctx ->
            if (ctx == null) {
                completePending(false)
                return@ensureCastContext
            }
            registerSessionListener(ctx)
            val session = ctx.sessionManager.currentCastSession
            if (!routeId.isNullOrBlank()) {
                val selected = matchingRoute(routeId)
                if (session?.isConnected == true && selected?.isSelected == true) {
                    loadOntoSession(session, media, completePending = true)
                } else if (selected != null) {
                    awaitingSessionForLoad = true
                    MediaRouter.getInstance(activity).selectRoute(selected)
                } else {
                    completePending(false)
                }
                return@ensureCastContext
            }
            if (session?.isConnected == true) {
                loadOntoSession(session, media, completePending = true)
            } else {
                awaitingSessionForLoad = true
                showDeviceChooser(ctx)
            }
        }
    }

    private fun handleStop(result: MethodChannel.Result) {
        ensureCastContext { ctx ->
            try {
                val client = ctx?.sessionManager?.currentCastSession?.remoteMediaClient
                client?.stop()
                ctx?.sessionManager?.endCurrentSession(true)
            } catch (_: Exception) {
            }
            result.success(null)
        }
    }

    private fun handleTransport(action: String, result: MethodChannel.Result) {
        ensureCastContext { ctx ->
            val client = ctx?.sessionManager?.currentCastSession?.remoteMediaClient
            if (client == null) {
                result.success(false)
                return@ensureCastContext
            }
            try {
                if (action == "play") client.play() else client.pause()
                try {
                    client.requestStatus()
                } catch (_: Exception) {
                }
                val st = client.mediaStatus
                if (st != null) emitMediaStatus(client, st, force = true)
                result.success(true)
            } catch (_: Exception) {
                result.success(false)
            }
        }
    }

    private fun handleSetPlaybackRate(call: MethodCall, result: MethodChannel.Result) {
        val rate = (call.argument<Number>("rate")?.toDouble() ?: 1.0).coerceIn(
            MediaLoadOptions.PLAYBACK_RATE_MIN,
            MediaLoadOptions.PLAYBACK_RATE_MAX,
        )
        ensureCastContext { ctx ->
            val client = ctx?.sessionManager?.currentCastSession?.remoteMediaClient
            if (client == null) {
                result.success(false)
                return@ensureCastContext
            }
            try {
                client.setPlaybackRate(rate)
                val st = client.mediaStatus
                if (st != null) emitMediaStatus(client, st, force = true)
                result.success(true)
            } catch (_: Exception) {
                result.success(false)
            }
        }
    }

    private fun handleSetVolume(call: MethodCall, result: MethodChannel.Result) {
        val level = (call.argument<Number>("level")?.toDouble() ?: 0.0).coerceIn(0.0, 1.0)
        ensureCastContext { ctx ->
            val session = ctx?.sessionManager?.currentCastSession
            if (session == null) {
                result.success(false)
                return@ensureCastContext
            }
            try {
                session.setMute(false)
                session.setVolume(level)
                emitVolume(session)
                result.success(true)
            } catch (_: Exception) {
                result.success(false)
            }
        }
    }

    private fun handleGetVolume(result: MethodChannel.Result) {
        ensureCastContext { ctx ->
            val session = ctx?.sessionManager?.currentCastSession
            if (session == null) {
                result.success(null)
                return@ensureCastContext
            }
            result.success(volumeMap(session))
        }
    }

    private fun emitVolume(session: CastSession) {
        try {
            channel.invokeMethod("onVolume", volumeMap(session))
        } catch (_: Exception) {
        }
    }

    private fun volumeMap(session: CastSession): Map<String, Any> {
        return mapOf(
            "level" to session.volume,
            "mute" to session.isMute,
        )
    }

    private fun handleSeek(call: MethodCall, result: MethodChannel.Result) {
        val ms = (call.argument<Number>("positionMs")?.toLong() ?: 0L).coerceAtLeast(0L)
        ensureCastContext { ctx ->
            val client = ctx?.sessionManager?.currentCastSession?.remoteMediaClient
            if (client == null) {
                result.success(false)
                return@ensureCastContext
            }
            try {
                val opts = MediaSeekOptions.Builder()
                    .setPosition(ms)
                    .setResumeState(MediaSeekOptions.RESUME_STATE_UNCHANGED)
                    .build()
                client.seek(opts)
                result.success(true)
            } catch (_: Exception) {
                result.success(false)
            }
        }
    }

    private fun startDiscovery() {
        if (routerCallbackRegistered) {
            emitDevices()
            return
        }
        val router = MediaRouter.getInstance(activity)
        // Touch CastContext so the Cast MediaRouteProvider is attached.
        castContext?.sessionManager
        router.addCallback(
            castSelector(),
            routerCallback,
            MediaRouter.CALLBACK_FLAG_REQUEST_DISCOVERY or
                MediaRouter.CALLBACK_FLAG_PERFORM_ACTIVE_SCAN,
        )
        routerCallbackRegistered = true
        emitDevices()
        // Routes often arrive a beat after the provider attaches.
        mainHandler.postDelayed({ emitDevices() }, 1500)
        mainHandler.postDelayed({ emitDevices() }, 4000)
    }

    private fun stopDiscovery() {
        if (!routerCallbackRegistered) return
        try {
            MediaRouter.getInstance(activity).removeCallback(routerCallback)
        } catch (_: Exception) {
        }
        routerCallbackRegistered = false
    }

    private fun emitDevices() {
        channel.invokeMethod("onCastDevices", currentDevices())
    }

    private fun currentDevices(): List<Map<String, String>> {
        val selector = castSelector()
        return MediaRouter.getInstance(activity).routes.mapNotNull { route ->
            if (!route.isEnabled || route.isDefault) return@mapNotNull null
            if (!route.matchesSelector(selector)) return@mapNotNull null
            val name = route.name?.toString()?.trim().orEmpty()
            if (name.isEmpty()) return@mapNotNull null
            mapOf("id" to route.id, "name" to name)
        }
    }

    private fun matchingRoute(routeId: String): MediaRouter.RouteInfo? {
        return MediaRouter.getInstance(activity).routes.firstOrNull { it.id == routeId }
    }

    private fun castSelector(): MediaRouteSelector {
        return MediaRouteSelector.Builder()
            .addControlCategory(
                CastMediaControlIntent.categoryForCast(
                    CastReceiverIds.forContext(activity),
                ),
            )
            .build()
    }

    private fun ensureCastContext(onReady: (CastContext?) -> Unit) {
        val existing = castContext
        if (existing != null) {
            mainHandler.post { onReady(existing) }
            return
        }
        try {
            CastContext.getSharedInstance(activity.applicationContext, castExecutor)
                .addOnCompleteListener { task ->
                    mainHandler.post {
                        if (task.isSuccessful) {
                            castContext = task.result
                            onReady(task.result)
                        } else {
                            try {
                                @Suppress("DEPRECATION")
                                castContext = CastContext.getSharedInstance(activity)
                                onReady(castContext)
                            } catch (_: Exception) {
                                onReady(null)
                            }
                        }
                    }
                }
        } catch (_: Exception) {
            mainHandler.post { onReady(null) }
        }
    }

    private fun registerSessionListener(ctx: CastContext) {
        if (sessionListenerRegistered) return
        ctx.sessionManager.addSessionManagerListener(
            sessionListener,
            CastSession::class.java,
        )
        sessionListenerRegistered = true
    }

    private fun showDeviceChooser(ctx: CastContext) {
        dismissChooser()
        val themed: Context = ContextThemeWrapper(
            activity,
            androidx.appcompat.R.style.Theme_AppCompat_Dialog_Alert,
        )
        ctx.sessionManager
        val dialog = MediaRouteChooserDialog(themed).apply {
            routeSelector = castSelector()
            setOnDismissListener {
                chooserDialog = null
                mainHandler.postDelayed({
                    if (awaitingSessionForLoad &&
                        castContext?.sessionManager?.currentCastSession?.isConnected != true
                    ) {
                        awaitingSessionForLoad = false
                        completePending(false)
                    }
                }, 400)
            }
        }
        chooserDialog = dialog
        dialog.show()
    }

    private fun dismissChooser() {
        try {
            chooserDialog?.dismiss()
        } catch (_: Exception) {
        }
        chooserDialog = null
    }

    private fun loadOntoSession(
        session: CastSession,
        media: PendingMedia,
        completePending: Boolean,
    ) {
        val client = session.remoteMediaClient
        if (client == null) {
            if (completePending) completePending(false)
            return
        }
        try {
            val metadata = MediaMetadata(MediaMetadata.MEDIA_TYPE_MOVIE).apply {
                putString(MediaMetadata.KEY_TITLE, media.title)
                media.subtitle?.let { putString(MediaMetadata.KEY_SUBTITLE, it) }
                media.posterUrl?.let { url ->
                    try {
                        addImage(WebImage(android.net.Uri.parse(url)))
                    } catch (_: Exception) {
                    }
                }
            }
            val contentType = media.contentType?.takeIf { it.isNotBlank() }
                ?: guessContentType(media.url)
            val isHls = contentType.contains("mpegURL", ignoreCase = true) ||
                contentType.contains("mpegurl", ignoreCase = true)
            val isMpegTs = contentType.contains("mp2t", ignoreCase = true)
            // HLS / torrent / MPEG-TS: seek on the initial LOAD blanks the TV.
            // Load at 0, then seek after PLAYING/BUFFERING (pendingSeekMs).
            val startMs = when {
                media.live || isHls || isMpegTs || media.deferSeek -> 0L
                else -> media.positionMs
            }
            val hlsSeg = media.hlsSegmentFormat?.lowercase()
            val useFmp4 = hlsSeg == "fmp4"
            // IPTV live HLS and progressive MPEG-TS often IDLE on
            // STREAM_TYPE_LIVE with the default receiver. BUFFERED + autoplay
            // still plays the live edge. Do not set hlsSegmentFormat on muxed
            // `.ts` — that is a progressive file, not an HLS playlist.
            val streamType = if (media.live && !isHls && !isMpegTs) {
                MediaInfo.STREAM_TYPE_LIVE
            } else {
                MediaInfo.STREAM_TYPE_BUFFERED
            }
            Log.i(
                TAG,
                "loadOntoSession live=${media.live} hls=$isHls startMs=$startMs " +
                    "type=$contentType stream=$streamType " +
                    "url=${redactUrl(media.url)} " +
                    "hlsSeg=${if (isHls) (if (useFmp4) "FMP4" else "TS") else "-"}",
            )
            val infoBuilder = MediaInfo.Builder(media.url)
                .setStreamType(streamType)
                .setContentType(contentType)
                .setMetadata(metadata)
            if (isHls) {
                if (useFmp4) {
                    infoBuilder
                        .setHlsSegmentFormat(HlsSegmentFormat.FMP4)
                        .setHlsVideoSegmentFormat(HlsVideoSegmentFormat.FMP4)
                } else {
                    infoBuilder
                        .setHlsSegmentFormat(HlsSegmentFormat.TS)
                        .setHlsVideoSegmentFormat(HlsVideoSegmentFormat.MPEG2_TS)
                }
            }
            val info = infoBuilder.build()
            val request = MediaLoadRequestData.Builder()
                .setMediaInfo(info)
                .setAutoplay(true)
                .setCurrentTime(startMs)
                .build()
            dismissChooser()
            pendingSeekMs = if (!media.live && media.positionMs > 2_000L) {
                media.positionMs
            } else {
                -1L
            }
            attachMediaCallback(client)
            val pending = client.load(request)
            pending.setResultCallback(
                ResultCallback<RemoteMediaClient.MediaChannelResult> { result ->
                    val status = result.status
                    if (status.isSuccess) {
                        if (completePending) completePending(true)
                    } else {
                        val msg = status.statusMessage?.takeIf { it.isNotBlank() }
                            ?: "Cast load failed (${status.statusCode})"
                        Log.e(TAG, msg)
                        channel.invokeMethod("onLoadFailed", msg)
                        if (completePending) completePending(false)
                    }
                },
            )
        } catch (e: Exception) {
            Log.e(TAG, "loadOntoSession failed", e)
            channel.invokeMethod("onLoadFailed", e.message ?: "Cast load failed")
            if (completePending) completePending(false)
        }
    }

    private fun attachMediaCallback(client: RemoteMediaClient) {
        mediaCallback?.let { client.unregisterCallback(it) }
        val cb = object : RemoteMediaClient.Callback() {
            override fun onStatusUpdated() {
                val st = client.mediaStatus ?: return
                emitMediaStatus(client, st, force = false)
                if (st.playerState == MediaStatus.PLAYER_STATE_IDLE &&
                    st.idleReason == MediaStatus.IDLE_REASON_ERROR
                ) {
                    Log.e(TAG, "Cast playback failed (idle error) state=${st.playerState}")
                    channel.invokeMethod("onLoadFailed", "Cast playback failed (idle error)")
                    return
                }
                val seekTo = pendingSeekMs
                if (seekTo < 0L) return
                if (st.playerState != MediaStatus.PLAYER_STATE_PLAYING &&
                    st.playerState != MediaStatus.PLAYER_STATE_BUFFERING
                ) {
                    return
                }
                val now = client.approximateStreamPosition
                if (now >= seekTo - 2_000L) {
                    pendingSeekMs = -1L
                    return
                }
                pendingSeekMs = -1L
                Log.i(TAG, "seek after HLS load to ${seekTo}ms (at ${now}ms)")
                try {
                    client.seek(seekTo)
                } catch (e: Exception) {
                    Log.e(TAG, "post-load seek failed", e)
                }
            }
        }
        mediaCallback = cb
        client.registerCallback(cb)
    }

    private fun emitMediaStatus(
        client: RemoteMediaClient,
        st: MediaStatus,
        force: Boolean = false,
    ) {
        val now = System.currentTimeMillis()
        if (!force &&
            now - lastStatusEmitAt < 400L &&
            st.playerState == MediaStatus.PLAYER_STATE_PLAYING
        ) {
            return
        }
        lastStatusEmitAt = now
        val playing = st.playerState == MediaStatus.PLAYER_STATE_PLAYING
        val buffering = st.playerState == MediaStatus.PLAYER_STATE_BUFFERING
        val duration = st.mediaInfo?.streamDuration ?: 0L
        channel.invokeMethod(
            "onMediaStatus",
            mapOf(
                "playing" to playing,
                "buffering" to buffering,
                "positionMs" to client.approximateStreamPosition,
                "durationMs" to duration,
                "playbackRate" to st.playbackRate,
            ),
        )
    }

    private fun completePending(ok: Boolean) {
        try {
            pendingResult?.success(ok)
        } catch (_: Exception) {
        }
        pendingResult = null
        if (!ok) pendingMedia = null
    }

    private data class PendingMedia(
        val url: String,
        val title: String,
        val subtitle: String?,
        val posterUrl: String?,
        val positionMs: Long,
        val live: Boolean = false,
        val contentType: String? = null,
        val deferSeek: Boolean = false,
        val hlsSegmentFormat: String? = null,
    )

    companion object {
        const val CHANNEL = "javp/chromecast"
        private const val TAG = "JavpCast"

        fun guessContentType(url: String): String {
            val lower = url.lowercase()
            val path = try {
                android.net.Uri.parse(url).path?.lowercase() ?: lower
            } catch (_: Exception) {
                lower
            }
            return when {
                // Google Cast samples use x-mpegURL for HLS.
                path.endsWith(".m3u8") || ".m3u8" in lower ||
                    lower.contains("type=m3u8") || lower.contains("format=m3u8") ->
                    "application/x-mpegURL"
                path.endsWith(".mpd") || ".mpd" in path -> "application/dash+xml"
                path.endsWith(".mp3") -> "audio/mpeg"
                path.endsWith(".aac") -> "audio/aac"
                path.endsWith(".webm") -> "video/webm"
                path.endsWith(".mkv") -> "video/x-matroska"
                path.endsWith(".mov") -> "video/quicktime"
                path.endsWith(".ts") || path.endsWith(".m2ts") ||
                    path.endsWith(".mts") -> "video/mp2t"
                else -> "video/mp4"
            }
        }

        /** Host + path only — drop query tokens from logcat. */
        fun redactUrl(url: String): String {
            return try {
                val u = android.net.Uri.parse(url)
                "${u.scheme}://${u.host}${u.path}"
            } catch (_: Exception) {
                "(url)"
            }
        }
    }
}
