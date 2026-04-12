package com.copyeverywhere.app.ui.config

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.automirrored.filled.BluetoothSearching
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.LinkOff
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.copyeverywhere.app.data.DiscoveredServer
import com.copyeverywhere.app.data.PairedBluetoothDevice
import com.copyeverywhere.app.data.TransferMode

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConfigScreen(
    onNavigateBack: () -> Unit,
    viewModel: ConfigViewModel = viewModel()
) {
    val hostUrl by viewModel.hostUrl.collectAsState()
    val deviceName by viewModel.deviceName.collectAsState()
    val accessToken by viewModel.accessToken.collectAsState()
    val deviceId by viewModel.deviceId.collectAsState()
    val targetDeviceId by viewModel.targetDeviceId.collectAsState()
    val serverAuthRequired by viewModel.serverAuthRequired.collectAsState()
    val connectionStatus by viewModel.connectionStatus.collectAsState()
    val devices by viewModel.devices.collectAsState()
    val discoveredServers by viewModel.discoveredServers.collectAsState()
    val transferMode by viewModel.transferMode.collectAsState()

    // Start/stop mDNS discovery with screen lifecycle (only in LAN mode)
    DisposableEffect(transferMode) {
        if (transferMode == TransferMode.LanServer) {
            viewModel.startDiscovery()
        }
        onDispose { viewModel.stopDiscovery() }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // Transfer Mode selector
            Text(
                text = "Transfer Mode",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                FilterChip(
                    selected = transferMode == TransferMode.LanServer,
                    onClick = { viewModel.updateTransferMode(TransferMode.LanServer) },
                    label = { Text("LAN Server") },
                    leadingIcon = {
                        Icon(Icons.Default.Wifi, contentDescription = null, modifier = Modifier.size(18.dp))
                    },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                        selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer
                    ),
                    modifier = Modifier.weight(1f)
                )
                FilterChip(
                    selected = transferMode == TransferMode.Bluetooth,
                    onClick = { viewModel.updateTransferMode(TransferMode.Bluetooth) },
                    label = { Text("Bluetooth") },
                    leadingIcon = {
                        Icon(Icons.Default.Bluetooth, contentDescription = null, modifier = Modifier.size(18.dp))
                    },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                        selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer
                    ),
                    modifier = Modifier.weight(1f)
                )
            }

            Spacer(modifier = Modifier.height(4.dp))

            // Device Name (shared across modes)
            OutlinedTextField(
                value = deviceName,
                onValueChange = { viewModel.updateDeviceName(it) },
                label = { Text("Device Name") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            // Device ID (read-only, shared)
            if (deviceId.isNotBlank()) {
                OutlinedTextField(
                    value = deviceId,
                    onValueChange = {},
                    label = { Text("Device ID") },
                    readOnly = true,
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            }

            // === LAN Server section ===
            if (transferMode == TransferMode.LanServer) {
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = "LAN Server",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.primary
                )

                // Host URL
                OutlinedTextField(
                    value = hostUrl,
                    onValueChange = { viewModel.updateHostUrl(it) },
                    label = { Text("Host URL") },
                    placeholder = { Text("http://192.168.1.100:8080") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                // Discovered Servers
                DiscoveredServersList(
                    servers = discoveredServers,
                    onSelect = { viewModel.selectDiscoveredServer(it) }
                )

                // Access Token — hidden when server reports auth: false
                if (serverAuthRequired != false) {
                    OutlinedTextField(
                        value = accessToken,
                        onValueChange = { viewModel.updateAccessToken(it) },
                        label = {
                            Text(
                                if (serverAuthRequired == true) "Access Token (required)"
                                else "Access Token"
                            )
                        },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        modifier = Modifier.fillMaxWidth()
                    )
                }

                // Target Device dropdown
                TargetDeviceDropdown(
                    selectedDeviceId = targetDeviceId,
                    devices = devices.filter { it.deviceId != deviceId },
                    onSelect = { viewModel.updateTargetDeviceId(it) }
                )

                Spacer(modifier = Modifier.height(4.dp))

                // Test Connection button
                Button(
                    onClick = { viewModel.testConnection() },
                    enabled = connectionStatus !is ConnectionStatus.Testing,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    if (connectionStatus is ConnectionStatus.Testing) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(20.dp),
                            strokeWidth = 2.dp,
                            color = MaterialTheme.colorScheme.onPrimary
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                    }
                    Text("Test Connection")
                }

                // Connection status
                when (val status = connectionStatus) {
                    is ConnectionStatus.Success -> {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                text = "Connected — ${status.latencyMs}ms",
                                color = MaterialTheme.colorScheme.primary,
                                style = MaterialTheme.typography.bodyMedium
                            )
                        }
                        Text(
                            text = if (status.authRequired) "Authentication: required" else "Authentication: not required",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    is ConnectionStatus.Error -> {
                        Text(
                            text = "Error: ${status.message}",
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodyMedium
                        )
                    }
                    else -> {}
                }
            }

            // === Bluetooth section ===
            if (transferMode == TransferMode.Bluetooth) {
                val pairedDevices by viewModel.pairedDevices.collectAsState()
                val discoveredBtDevices by viewModel.discoveredBtDevices.collectAsState()
                val btConnectionStatus by viewModel.btConnectionStatus.collectAsState()
                val connectedDeviceName by viewModel.connectedDeviceName.collectAsState()
                val isScanning by viewModel.isScanning.collectAsState()

                // Runtime permission launcher for BLUETOOTH_CONNECT + BLUETOOTH_SCAN
                var btPermissionsGranted by remember { mutableStateOf(false) }
                val btPermissionLauncher = rememberLauncherForActivityResult(
                    ActivityResultContracts.RequestMultiplePermissions()
                ) { results ->
                    btPermissionsGranted = results.values.all { it }
                    if (btPermissionsGranted) {
                        viewModel.startBluetoothScan()
                    }
                }

                // Stop scanning when leaving Bluetooth section
                DisposableEffect(Unit) {
                    onDispose { viewModel.stopBluetoothScan() }
                }

                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = "Bluetooth",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.primary
                )

                // Connection status indicator
                BluetoothStatusCard(
                    status = btConnectionStatus,
                    connectedDeviceName = connectedDeviceName,
                    onDisconnect = { viewModel.disconnectBluetooth() }
                )

                // Paired devices
                if (pairedDevices.isNotEmpty()) {
                    Text(
                        text = "Paired Devices",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    pairedDevices.forEach { device ->
                        PairedDeviceCard(
                            device = device,
                            isConnected = btConnectionStatus == BluetoothConnectionStatus.Connected &&
                                connectedDeviceName == device.name,
                            isConnecting = btConnectionStatus == BluetoothConnectionStatus.Connecting,
                            onConnect = { viewModel.connectBluetoothDevice(device.address) },
                            onDisconnect = { viewModel.disconnectBluetooth() },
                            onForget = { viewModel.forgetPairedDevice(device.address) }
                        )
                    }
                }

                Spacer(modifier = Modifier.height(8.dp))

                // Scan button
                Button(
                    onClick = {
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
                            btPermissionLauncher.launch(
                                arrayOf(
                                    android.Manifest.permission.BLUETOOTH_CONNECT,
                                    android.Manifest.permission.BLUETOOTH_SCAN
                                )
                            )
                        } else {
                            viewModel.startBluetoothScan()
                        }
                    },
                    enabled = !isScanning,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    if (isScanning) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(20.dp),
                            strokeWidth = 2.dp,
                            color = MaterialTheme.colorScheme.onPrimary
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("Scanning...")
                    } else {
                        Icon(
                            Icons.AutoMirrored.Filled.BluetoothSearching,
                            contentDescription = null,
                            modifier = Modifier.size(20.dp)
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("Scan for Devices")
                    }
                }

                // Discovered devices
                if (discoveredBtDevices.isNotEmpty()) {
                    Text(
                        text = "Discovered Devices",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    discoveredBtDevices.forEach { device ->
                        Card(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    viewModel.stopBluetoothScan()
                                    viewModel.connectBluetoothDevice(device.address)
                                },
                            colors = CardDefaults.cardColors(
                                containerColor = MaterialTheme.colorScheme.surfaceVariant
                            )
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(12.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(
                                    Icons.Default.Bluetooth,
                                    contentDescription = null,
                                    modifier = Modifier.size(20.dp),
                                    tint = MaterialTheme.colorScheme.primary
                                )
                                Spacer(modifier = Modifier.width(12.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = device.name,
                                        style = MaterialTheme.typography.bodyMedium
                                    )
                                    Text(
                                        text = device.address,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                                Text(
                                    text = "Pair",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.primary
                                )
                            }
                        }
                    }
                } else if (isScanning) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(vertical = 4.dp)
                    ) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            text = "Looking for nearby devices...",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(16.dp))
        }
    }
}

@Composable
private fun DiscoveredServersList(
    servers: List<DiscoveredServer>,
    onSelect: (DiscoveredServer) -> Unit
) {
    if (servers.isEmpty()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(vertical = 4.dp)
        ) {
            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = "Scanning for servers...",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    } else {
        Text(
            text = "Discovered Servers",
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        servers.forEach { server ->
            Card(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onSelect(server) },
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant
                )
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        Icons.Default.Wifi,
                        contentDescription = null,
                        modifier = Modifier.size(20.dp),
                        tint = MaterialTheme.colorScheme.primary
                    )
                    Spacer(modifier = Modifier.width(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = server.name,
                            style = MaterialTheme.typography.bodyMedium
                        )
                        Text(
                            text = buildString {
                                append("${server.host}:${server.port}")
                                server.version?.let { append(" \u00B7 v$it") }
                                server.authRequired?.let { auth ->
                                    append(if (auth) " \u00B7 auth required" else " \u00B7 no auth")
                                }
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TargetDeviceDropdown(
    selectedDeviceId: String,
    devices: List<com.copyeverywhere.app.data.Device>,
    onSelect: (String) -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    val selectedDevice = devices.find { it.deviceId == selectedDeviceId }
    val displayText = selectedDevice?.let { "${it.name} (${it.platform})" } ?: if (selectedDeviceId.isNotBlank()) selectedDeviceId else "Select target device"

    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = it }
    ) {
        OutlinedTextField(
            value = displayText,
            onValueChange = {},
            readOnly = true,
            label = { Text("Target Device") },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier
                .fillMaxWidth()
                .menuAnchor(MenuAnchorType.PrimaryNotEditable)
        )
        ExposedDropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false }
        ) {
            if (devices.isEmpty()) {
                DropdownMenuItem(
                    text = { Text("No devices available") },
                    onClick = { expanded = false },
                    enabled = false
                )
            } else {
                devices.forEach { device ->
                    DropdownMenuItem(
                        text = { Text("${device.name} (${device.platform})") },
                        onClick = {
                            onSelect(device.deviceId)
                            expanded = false
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun BluetoothStatusCard(
    status: BluetoothConnectionStatus,
    connectedDeviceName: String,
    onDisconnect: () -> Unit
) {
    val (dotColor, statusText) = when (status) {
        BluetoothConnectionStatus.Connected -> MaterialTheme.colorScheme.primary to "Connected to $connectedDeviceName"
        BluetoothConnectionStatus.Connecting -> MaterialTheme.colorScheme.tertiary to "Connecting..."
        BluetoothConnectionStatus.Disconnected -> MaterialTheme.colorScheme.outline to "Disconnected"
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .clip(CircleShape)
                    .background(dotColor)
            )
            Spacer(modifier = Modifier.width(12.dp))
            Text(
                text = statusText,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.weight(1f)
            )
            if (status == BluetoothConnectionStatus.Connected) {
                IconButton(
                    onClick = onDisconnect,
                    modifier = Modifier.size(32.dp)
                ) {
                    Icon(
                        Icons.Default.LinkOff,
                        contentDescription = "Disconnect",
                        modifier = Modifier.size(18.dp)
                    )
                }
            }
            if (status == BluetoothConnectionStatus.Connecting) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp
                )
            }
        }
    }
}

@Composable
private fun PairedDeviceCard(
    device: PairedBluetoothDevice,
    isConnected: Boolean,
    isConnecting: Boolean,
    onConnect: () -> Unit,
    onDisconnect: () -> Unit,
    onForget: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Status dot
            val dotColor = when {
                isConnected -> MaterialTheme.colorScheme.primary
                isConnecting -> MaterialTheme.colorScheme.tertiary
                else -> MaterialTheme.colorScheme.outline
            }
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(dotColor)
            )
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = device.name,
                    style = MaterialTheme.typography.bodyMedium
                )
                Text(
                    text = device.address,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            if (isConnected) {
                TextButton(onClick = onDisconnect) {
                    Text("Disconnect")
                }
            } else {
                TextButton(onClick = onConnect, enabled = !isConnecting) {
                    Text("Connect")
                }
            }
            IconButton(
                onClick = onForget,
                modifier = Modifier.size(32.dp)
            ) {
                Icon(
                    Icons.Default.Close,
                    contentDescription = "Forget",
                    modifier = Modifier.size(16.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}
