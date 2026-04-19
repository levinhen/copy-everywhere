package com.copyeverywhere.app.ui.config

import android.annotation.SuppressLint
import android.app.Application
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.copyeverywhere.app.data.ApiClient
import com.copyeverywhere.app.data.BluetoothService
import com.copyeverywhere.app.data.BluetoothSession
import com.copyeverywhere.app.data.ConfigStore
import com.copyeverywhere.app.data.Device
import com.copyeverywhere.app.data.DiscoveredServer
import com.copyeverywhere.app.data.PairedBluetoothDevice
import com.copyeverywhere.app.data.LanEndpointSource
import com.copyeverywhere.app.data.StoredLanServerSelection
import com.copyeverywhere.app.data.TransferMode
import com.copyeverywhere.app.service.CopyEverywhereService
import com.copyeverywhere.app.service.LanReceiverHealth
import com.copyeverywhere.app.service.LanReceiverStatus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

enum class BluetoothConnectionStatus {
    Disconnected,
    Connecting,
    Connected
}

data class DiscoveredBluetoothDevice(
    val name: String,
    val address: String,
    val device: BluetoothDevice
)

class ConfigViewModel(application: Application) : AndroidViewModel(application) {

    val configStore = ConfigStore(application)
    private val apiClient = ApiClient()

    val hostUrl: StateFlow<String> = configStore.hostUrl
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")
    val deviceName: StateFlow<String> = configStore.deviceName
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), android.os.Build.MODEL)
    val deviceId: StateFlow<String> = configStore.deviceId
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")
    val targetDeviceId: StateFlow<String> = configStore.targetDeviceId
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")
    val transferMode: StateFlow<TransferMode> = configStore.transferMode
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), TransferMode.LanServer)
    val lanReceiverHealth: StateFlow<LanReceiverHealth> = CopyEverywhereService.receiverHealth
        .stateIn(
            viewModelScope,
            SharingStarted.WhileSubscribed(5000),
            LanReceiverHealth(
                status = LanReceiverStatus.Unavailable,
                detail = "Foreground service is not running"
            )
        )

    private val _accessToken = MutableStateFlow(configStore.getAccessToken())
    val accessToken: StateFlow<String> = _accessToken.asStateFlow()

    private val _serverAuthRequired = MutableStateFlow<Boolean?>(null)
    val serverAuthRequired: StateFlow<Boolean?> = _serverAuthRequired.asStateFlow()

    private val _connectionStatus = MutableStateFlow<ConnectionStatus>(ConnectionStatus.Idle)
    val connectionStatus: StateFlow<ConnectionStatus> = _connectionStatus.asStateFlow()

    private val _devices = MutableStateFlow<List<Device>>(emptyList())
    val devices: StateFlow<List<Device>> = _devices.asStateFlow()

    val discoveredServers: StateFlow<List<DiscoveredServer>> = CopyEverywhereService.discoveredLanServers
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val lanEndpointSource: StateFlow<LanEndpointSource> = configStore.lanEndpointSource
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), LanEndpointSource.ManualFallback)
    val selectedLanServer: StateFlow<StoredLanServerSelection?> = configStore.selectedLanServer
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    // Bluetooth state
    val pairedDevices: StateFlow<List<PairedBluetoothDevice>> = configStore.pairedBluetoothDevices
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val _discoveredBtDevices = MutableStateFlow<List<DiscoveredBluetoothDevice>>(emptyList())
    val discoveredBtDevices: StateFlow<List<DiscoveredBluetoothDevice>> = _discoveredBtDevices.asStateFlow()

    private val _btConnectionStatus = MutableStateFlow(BluetoothConnectionStatus.Disconnected)
    val btConnectionStatus: StateFlow<BluetoothConnectionStatus> = _btConnectionStatus.asStateFlow()

    private val _connectedDeviceName = MutableStateFlow("")
    val connectedDeviceName: StateFlow<String> = _connectedDeviceName.asStateFlow()

    private val _isScanning = MutableStateFlow(false)
    val isScanning: StateFlow<Boolean> = _isScanning.asStateFlow()

    private var discoveryReceiver: BroadcastReceiver? = null

    private val bluetoothServiceListener = object : BluetoothService.Listener {
        override fun onSessionReady(session: BluetoothSession) {
            _btConnectionStatus.value = BluetoothConnectionStatus.Connected
            _connectedDeviceName.value = session.deviceName
            // Persist paired device
            viewModelScope.launch {
                configStore.addPairedDevice(
                    PairedBluetoothDevice(session.deviceName, session.deviceAddress)
                )
                configStore.setLastConnectedBtAddress(session.deviceAddress)
            }
        }
        override fun onSessionHandshakeFailed(session: BluetoothSession, error: Exception) {
            _btConnectionStatus.value = BluetoothConnectionStatus.Disconnected
            _connectedDeviceName.value = ""
        }
        override fun onTransferReceived(session: BluetoothSession, payload: com.copyeverywhere.app.data.BluetoothPayload) {}
        override fun onReceiveProgress(session: BluetoothSession, progress: Double, header: com.copyeverywhere.app.data.BluetoothTransferHeader) {}
        override fun onReceiveFailed(session: BluetoothSession, error: Exception) {}
        override fun onSessionDisconnected(session: BluetoothSession) {
            _btConnectionStatus.value = BluetoothConnectionStatus.Disconnected
            _connectedDeviceName.value = ""
        }
    }

    init {
        // Check if there's already an active Bluetooth session
        val btService = CopyEverywhereService.instance?.bluetoothService
        if (btService != null) {
            btService.listener = bluetoothServiceListener
            if (btService.isSessionReady) {
                _btConnectionStatus.value = BluetoothConnectionStatus.Connected
                _connectedDeviceName.value = btService.activeSession?.deviceName ?: ""
            }
        }
    }

    fun updateHostUrl(url: String) {
        viewModelScope.launch { configStore.updateManualHostUrl(url) }
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

    fun updateTransferMode(mode: TransferMode) {
        viewModelScope.launch {
            configStore.setTransferMode(mode)
            // Notify the running service to switch modes
            CopyEverywhereService.instance?.switchMode(mode)
        }
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

    fun selectDiscoveredServer(server: DiscoveredServer) {
        viewModelScope.launch {
            configStore.selectDiscoveredServer(
                server = server,
                source = LanEndpointSource.RestoredSelection
            )
        }
        _serverAuthRequired.value = server.authRequired
    }

    // --- Bluetooth scanning and pairing ---

    @SuppressLint("MissingPermission")
    fun startBluetoothScan() {
        val app = getApplication<Application>()
        val manager = app.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = manager?.adapter
        if (adapter == null || !adapter.isEnabled) {
            Log.w(TAG, "Bluetooth not available or not enabled")
            return
        }

        _discoveredBtDevices.value = emptyList()
        _isScanning.value = true

        // Register broadcast receiver for discovered devices
        stopBluetoothScan() // clean up any previous receiver

        val receiver = object : BroadcastReceiver() {
            @SuppressLint("MissingPermission")
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    BluetoothDevice.ACTION_FOUND -> {
                        val device: BluetoothDevice = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        } ?: return

                        val name = try { device.name } catch (_: SecurityException) { null }
                        if (name.isNullOrBlank()) return // Skip unnamed devices

                        val existing = _discoveredBtDevices.value
                        if (existing.any { it.address == device.address }) return

                        _discoveredBtDevices.value = existing + DiscoveredBluetoothDevice(
                            name = name,
                            address = device.address,
                            device = device
                        )
                    }
                    BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                        _isScanning.value = false
                    }
                }
            }
        }
        discoveryReceiver = receiver

        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            app.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            app.registerReceiver(receiver, filter)
        }

        adapter.startDiscovery()
    }

    @SuppressLint("MissingPermission")
    fun stopBluetoothScan() {
        val app = getApplication<Application>()
        discoveryReceiver?.let {
            try { app.unregisterReceiver(it) } catch (_: Exception) {}
        }
        discoveryReceiver = null

        val manager = app.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        try { manager?.adapter?.cancelDiscovery() } catch (_: SecurityException) {}
        _isScanning.value = false
    }

    fun connectBluetoothDevice(address: String) {
        val btService = CopyEverywhereService.instance?.bluetoothService ?: return
        btService.listener = bluetoothServiceListener
        _btConnectionStatus.value = BluetoothConnectionStatus.Connecting
        btService.connectByAddress(address)
    }

    fun disconnectBluetooth() {
        val btService = CopyEverywhereService.instance?.bluetoothService ?: return
        btService.disconnectSession()
        _btConnectionStatus.value = BluetoothConnectionStatus.Disconnected
        _connectedDeviceName.value = ""
    }

    fun forgetPairedDevice(address: String) {
        // Disconnect if this is the connected device
        val btService = CopyEverywhereService.instance?.bluetoothService
        if (btService?.activeSession?.deviceAddress == address) {
            disconnectBluetooth()
        }
        viewModelScope.launch {
            configStore.removePairedDevice(address)
        }
    }

    override fun onCleared() {
        super.onCleared()
        stopBluetoothScan()
        // Restore service as the Bluetooth listener when ViewModel goes away
        val service = CopyEverywhereService.instance
        val btService = service?.bluetoothService
        if (btService?.listener === bluetoothServiceListener) {
            btService.listener = service
        }
    }

    companion object {
        private const val TAG = "ConfigViewModel"
    }
}

sealed class ConnectionStatus {
    data object Idle : ConnectionStatus()
    data object Testing : ConnectionStatus()
    data class Success(val latencyMs: Long, val authRequired: Boolean) : ConnectionStatus()
    data class Error(val message: String) : ConnectionStatus()
}
