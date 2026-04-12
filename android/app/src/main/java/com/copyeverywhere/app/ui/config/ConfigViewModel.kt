package com.copyeverywhere.app.ui.config

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.copyeverywhere.app.data.ApiClient
import com.copyeverywhere.app.data.ConfigStore
import com.copyeverywhere.app.data.Device
import com.copyeverywhere.app.data.DiscoveredServer
import com.copyeverywhere.app.data.MdnsDiscoveryService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class ConfigViewModel(application: Application) : AndroidViewModel(application) {

    val configStore = ConfigStore(application)
    private val apiClient = ApiClient()
    private val mdnsDiscovery = MdnsDiscoveryService(application)

    val hostUrl: StateFlow<String> = configStore.hostUrl
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")
    val deviceName: StateFlow<String> = configStore.deviceName
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), android.os.Build.MODEL)
    val deviceId: StateFlow<String> = configStore.deviceId
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")
    val targetDeviceId: StateFlow<String> = configStore.targetDeviceId
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    private val _accessToken = MutableStateFlow(configStore.getAccessToken())
    val accessToken: StateFlow<String> = _accessToken.asStateFlow()

    private val _serverAuthRequired = MutableStateFlow<Boolean?>(null)
    val serverAuthRequired: StateFlow<Boolean?> = _serverAuthRequired.asStateFlow()

    private val _connectionStatus = MutableStateFlow<ConnectionStatus>(ConnectionStatus.Idle)
    val connectionStatus: StateFlow<ConnectionStatus> = _connectionStatus.asStateFlow()

    private val _devices = MutableStateFlow<List<Device>>(emptyList())
    val devices: StateFlow<List<Device>> = _devices.asStateFlow()

    val discoveredServers: StateFlow<List<DiscoveredServer>> = mdnsDiscovery.servers

    fun updateHostUrl(url: String) {
        viewModelScope.launch { configStore.setHostUrl(url) }
    }

    fun updateDeviceName(name: String) {
        viewModelScope.launch { configStore.setDeviceName(name) }
    }

    fun updateAccessToken(token: String) {
        configStore.setAccessToken(token)
        _accessToken.value = token
    }

    fun updateTargetDeviceId(id: String) {
        viewModelScope.launch { configStore.setTargetDeviceId(id) }
    }

    fun testConnection() {
        viewModelScope.launch {
            _connectionStatus.value = ConnectionStatus.Testing
            try {
                val url = hostUrl.value
                if (url.isBlank()) {
                    _connectionStatus.value = ConnectionStatus.Error("Host URL is empty")
                    return@launch
                }
                val token = _accessToken.value
                val result = apiClient.checkHealth(url, token)
                _serverAuthRequired.value = result.response.auth

                // Auto-register device if not yet registered
                val currentDeviceId = deviceId.value
                if (currentDeviceId.isBlank()) {
                    val name = deviceName.value
                    val effectiveToken = if (result.response.auth) token else ""
                    val newId = apiClient.registerDevice(url, effectiveToken, name)
                    configStore.setDeviceId(newId)
                }

                // Fetch device list
                val effectiveToken = if (result.response.auth) token else ""
                val deviceList = apiClient.listDevices(url, effectiveToken)
                _devices.value = deviceList

                _connectionStatus.value = ConnectionStatus.Success(result.latencyMs, result.response.auth)
            } catch (e: Exception) {
                _connectionStatus.value = ConnectionStatus.Error(e.message ?: "Unknown error")
            }
        }
    }

    fun refreshDevices() {
        viewModelScope.launch {
            try {
                val url = hostUrl.value
                if (url.isBlank()) return@launch
                val token = _accessToken.value
                val deviceList = apiClient.listDevices(url, token)
                _devices.value = deviceList
            } catch (_: Exception) {
                // silently fail — device list is non-critical
            }
        }
    }

    fun startDiscovery() {
        mdnsDiscovery.startDiscovery()
    }

    fun stopDiscovery() {
        mdnsDiscovery.stopDiscovery()
    }

    fun selectDiscoveredServer(server: DiscoveredServer) {
        val url = "http://${server.host}:${server.port}"
        viewModelScope.launch { configStore.setHostUrl(url) }
        _serverAuthRequired.value = server.authRequired
    }

    override fun onCleared() {
        super.onCleared()
        mdnsDiscovery.stopDiscovery()
    }
}

sealed class ConnectionStatus {
    data object Idle : ConnectionStatus()
    data object Testing : ConnectionStatus()
    data class Success(val latencyMs: Long, val authRequired: Boolean) : ConnectionStatus()
    data class Error(val message: String) : ConnectionStatus()
}
