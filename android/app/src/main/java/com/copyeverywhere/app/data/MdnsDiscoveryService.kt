package com.copyeverywhere.app.data

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class DiscoveredServer(
    val serverId: String?,
    val name: String,
    val host: String,
    val port: Int,
    val authRequired: Boolean?,
    val version: String?
)

class MdnsDiscoveryService(context: Context) {

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val _servers = MutableStateFlow<List<DiscoveredServer>>(emptyList())
    val servers: StateFlow<List<DiscoveredServer>> = _servers.asStateFlow()
    private val _isDiscovering = MutableStateFlow(false)
    val isDiscovering: StateFlow<Boolean> = _isDiscovering.asStateFlow()
    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    private var discoveryActive = false
    private val pendingResolves = mutableSetOf<String>()

    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) {
            discoveryActive = true
            _isDiscovering.value = true
            _lastError.value = null
        }

        override fun onDiscoveryStopped(serviceType: String) {
            discoveryActive = false
            _isDiscovering.value = false
        }

        override fun onServiceFound(serviceInfo: NsdServiceInfo) {
            val serviceName = serviceInfo.serviceName
            if (serviceName in pendingResolves) return
            pendingResolves.add(serviceName)
            nsdManager.resolveService(serviceInfo, createResolveListener(serviceName))
        }

        override fun onServiceLost(serviceInfo: NsdServiceInfo) {
            _servers.value = _servers.value.filter { it.name != serviceInfo.serviceName }
            pendingResolves.remove(serviceInfo.serviceName)
        }

        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            discoveryActive = false
            _isDiscovering.value = false
            _lastError.value = "Android NSD error $errorCode"
        }

        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
            discoveryActive = false
            _isDiscovering.value = false
            _lastError.value = "Android NSD stop error $errorCode"
        }
    }

    private fun createResolveListener(serviceName: String) = object : NsdManager.ResolveListener {
        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
            pendingResolves.remove(serviceName)
            _lastError.value = "Resolve failed for $serviceName ($errorCode)"
        }

        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
            pendingResolves.remove(serviceName)
            val host = serviceInfo.host?.hostAddress ?: return
            val port = serviceInfo.port
            val attributes = serviceInfo.attributes
            val authRequired = attributes["auth"]?.let { String(it) == "true" }
            val version = attributes["version"]?.let { String(it) }
            val serverId = attributes["server_id"]?.let { String(it) }

            val server = DiscoveredServer(
                serverId = serverId,
                name = serviceInfo.serviceName,
                host = host,
                port = port,
                authRequired = authRequired,
                version = version
            )

            _servers.value = _servers.value
                .filter { it.name != server.name } + server
            _lastError.value = null
        }
    }

    fun startDiscovery() {
        if (discoveryActive) return
        _servers.value = emptyList()
        pendingResolves.clear()
        _lastError.value = null
        nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    }

    fun stopDiscovery() {
        if (!discoveryActive) return
        try {
            nsdManager.stopServiceDiscovery(discoveryListener)
        } catch (_: IllegalArgumentException) {
            // Listener not registered — ignore
        }
        discoveryActive = false
        _isDiscovering.value = false
    }

    companion object {
        private const val SERVICE_TYPE = "_copyeverywhere._tcp."
    }
}
