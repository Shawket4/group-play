// Local-only hotspot (host) and joining a given Wi-Fi network (guest).

package com.shawket.tutti

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.net.Inet4Address
import java.net.NetworkInterface

object NetHelpers {
    private const val TAG = "tutti-net"
    private val main = Handler(Looper.getMainLooper())
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null

    var onHotspotStopped: (() -> Unit)? = null
    var onWifiLost: (() -> Unit)? = null

    fun localIpv4(): List<String> = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .map { it.hostAddress ?: "" }
            .filter { it.isNotEmpty() }
    } catch (_: Throwable) {
        emptyList()
    }

    @SuppressLint("MissingPermission")
    fun startHotspot(ctx: Context, done: (Result<Map<String, Any>>) -> Unit) {
        val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        reservation?.let { r ->
            done(Result.success(describe(r))); return
        }
        try {
            wm.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(r: WifiManager.LocalOnlyHotspotReservation) {
                    reservation = r
                    // the interface gets its address a moment after onStarted
                    main.postDelayed({ done(Result.success(describe(r))) }, 600)
                }

                override fun onStopped() {
                    reservation = null
                    onHotspotStopped?.invoke()
                }

                override fun onFailed(reason: Int) {
                    val why = when (reason) {
                        ERROR_NO_CHANNEL -> "no free Wi-Fi channel"
                        ERROR_GENERIC -> "the phone refused (is the normal hotspot on?)"
                        ERROR_INCOMPATIBLE_MODE -> "incompatible with the current Wi-Fi mode (turn off the normal hotspot)"
                        ERROR_TETHERING_DISALLOWED -> "tethering is disallowed on this phone"
                        else -> "error $reason"
                    }
                    done(Result.failure(IllegalStateException("Hotspot failed: $why")))
                }
            }, main)
        } catch (e: Throwable) {
            done(Result.failure(e))
        }
    }

    @Suppress("DEPRECATION")
    private fun describe(r: WifiManager.LocalOnlyHotspotReservation): Map<String, Any> {
        var ssid = ""
        var pass = ""
        if (Build.VERSION.SDK_INT >= 30) {
            val c = r.softApConfiguration
            ssid = if (Build.VERSION.SDK_INT >= 33) c.wifiSsid?.toString()?.trim('"') ?: "" else c.ssid ?: ""
            pass = c.passphrase ?: ""
        } else {
            val c = r.wifiConfiguration
            ssid = c?.SSID?.trim('"') ?: ""
            pass = c?.preSharedKey?.trim('"') ?: ""
        }
        return mapOf("ssid" to ssid, "passphrase" to pass, "ips" to localIpv4())
    }

    fun stopHotspot() {
        reservation?.close()
        reservation = null
    }

    fun joinWifi(ctx: Context, ssid: String, passphrase: String, done: (Result<Boolean>) -> Unit) {
        if (Build.VERSION.SDK_INT < 29) {
            done(Result.failure(IllegalStateException("Join '$ssid' in Wi-Fi settings, then come back."))); return
        }
        val cm = ctx.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        leaveWifi(ctx)
        val spec = WifiNetworkSpecifier.Builder().setSsid(ssid).apply {
            if (passphrase.isNotEmpty()) setWpa2Passphrase(passphrase)
        }.build()
        val req = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(spec)
            .build()
        var answered = false
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                cm.bindProcessToNetwork(network)
                Log.i(TAG, "joined $ssid, process bound to it")
                main.post { if (!answered) { answered = true; done(Result.success(true)) } }
            }

            override fun onUnavailable() {
                main.post { if (!answered) { answered = true; done(Result.success(false)) } }
            }

            override fun onLost(network: Network) {
                cm.bindProcessToNetwork(null)
                main.post { onWifiLost?.invoke() }
            }
        }
        wifiCallback = cb
        try {
            cm.requestNetwork(req, cb, 60_000)
        } catch (e: Throwable) {
            wifiCallback = null
            done(Result.failure(e))
        }
    }

    fun leaveWifi(ctx: Context) {
        val cm = ctx.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        wifiCallback?.let { try { cm.unregisterNetworkCallback(it) } catch (_: Throwable) {} }
        wifiCallback = null
        cm.bindProcessToNetwork(null)
    }
}
