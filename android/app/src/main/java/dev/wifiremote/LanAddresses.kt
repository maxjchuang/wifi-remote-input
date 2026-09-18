// SPDX-License-Identifier: AGPL-3.0-only
package dev.wifiremote

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.Inet4Address
import java.net.NetworkInterface

object LanAddresses {
    fun find(context: Context): List<String> = try {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        // Prefer Wi-Fi over mobile data or VPN interfaces; retain a choice for hotspots/multiple LANs.
        val wifi = manager.allNetworks.filter { manager.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true }
            .flatMap { manager.getLinkProperties(it)?.linkAddresses.orEmpty() }.map { it.address }
        val other = NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }.flatMap { it.inetAddresses.toList() }
        (wifi + other).filter { it is Inet4Address && it.isSiteLocalAddress }.map { "${it.hostAddress}:8765" }.distinct()
    } catch (_: Exception) { emptyList() }
}
