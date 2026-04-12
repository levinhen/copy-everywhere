package com.copyeverywhere.app.ui.config

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Bluetooth
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
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
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
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.copyeverywhere.app.data.DiscoveredServer
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
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = "Bluetooth",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.primary
                )

                // Placeholder for Bluetooth device scanning and pairing (US-063)
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant
                    )
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text(
                            text = "Bluetooth device pairing will be available in a future update.",
                            style = MaterialTheme.typography.bodyMedium,
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
