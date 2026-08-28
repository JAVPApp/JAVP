package com.javp.javp

import android.app.Activity
import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Holds a Wi-Fi multicast lock so SSDP / mDNS discovery works on Android. */
class LanMulticastLock(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)
    private var lock: WifiManager.MulticastLock? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "acquire" -> {
                acquire()
                result.success(null)
            }
            "release" -> {
                release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun acquire() {
        if (lock?.isHeld == true) return
        val wifi = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: return
        val created = lock ?: wifi.createMulticastLock("javp-lan-cast").also {
            it.setReferenceCounted(false)
            lock = it
        }
        try {
            created.acquire()
        } catch (_: Exception) {
        }
    }

    fun release() {
        try {
            if (lock?.isHeld == true) lock?.release()
        } catch (_: Exception) {
        }
    }

    fun detach() {
        release()
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL = "javp/lan_multicast"
    }
}
