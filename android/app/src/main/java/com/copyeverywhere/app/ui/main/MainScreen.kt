package com.copyeverywhere.app.ui.main

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.UploadFile
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.copyeverywhere.app.data.ClipResponse

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    onNavigateToConfig: () -> Unit,
    viewModel: MainViewModel = viewModel()
) {
    val textInput by viewModel.textInput.collectAsState()
    val sendStatus by viewModel.sendStatus.collectAsState()
    val queue by viewModel.queue.collectAsState()
    val uploadProgress by viewModel.uploadProgress.collectAsState()
    val receiveStatus by viewModel.receiveStatus.collectAsState()

    val filePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri?.let { viewModel.sendFile(it) }
    }

    DisposableEffect(Unit) {
        viewModel.startQueuePolling()
        onDispose { viewModel.stopQueuePolling() }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("CopyEverywhere") },
                actions = {
                    IconButton(onClick = onNavigateToConfig) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings")
                    }
                }
            )
        }
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // Text input section
            item {
                Text("Send Text", style = MaterialTheme.typography.titleMedium)
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedTextField(
                    value = textInput,
                    onValueChange = { viewModel.updateTextInput(it) },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text("Enter text to send...") },
                    minLines = 2,
                    maxLines = 5
                )
                Spacer(modifier = Modifier.height(8.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Button(
                        onClick = { viewModel.sendText() },
                        enabled = textInput.isNotBlank() && sendStatus !is SendStatus.Sending
                    ) {
                        Icon(Icons.AutoMirrored.Filled.Send, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("Send")
                    }
                    OutlinedButton(
                        onClick = { filePickerLauncher.launch(arrayOf("*/*")) },
                        enabled = sendStatus !is SendStatus.Sending && uploadProgress == null
                    ) {
                        Icon(Icons.Default.UploadFile, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("Upload File")
                    }
                }
            }

            // Send status
            item {
                when (val status = sendStatus) {
                    is SendStatus.Sending -> {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Sending...", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    is SendStatus.Success -> {
                        Text("Sent!", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodySmall)
                    }
                    is SendStatus.Error -> {
                        Text(status.message, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                    }
                    else -> {}
                }
            }

            // Upload progress
            val progress = uploadProgress
            if (progress != null) {
                item {
                    UploadProgressCard(
                        progress = progress,
                        onPause = { viewModel.pauseUpload() },
                        onResume = { viewModel.resumeUpload() }
                    )
                }
            }

            // Queue section
            item {
                Spacer(modifier = Modifier.height(8.dp))
                Text("Queue", style = MaterialTheme.typography.titleMedium)
            }

            if (queue.isEmpty()) {
                item {
                    Text(
                        "No pending clips",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            } else {
                items(queue, key = { it.id }) { clip ->
                    val isReceiving = receiveStatus is ReceiveStatus.Receiving &&
                            (receiveStatus as ReceiveStatus.Receiving).clipId == clip.id
                    QueueItemCard(
                        clip = clip,
                        isReceiving = isReceiving,
                        onClick = { viewModel.receiveQueueItem(clip) }
                    )
                }
            }

            // Bottom spacing
            item { Spacer(modifier = Modifier.height(16.dp)) }
        }
    }
}

@Composable
private fun UploadProgressCard(
    progress: UploadProgress,
    onPause: () -> Unit,
    onResume: () -> Unit
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(progress.fileName, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        "${(progress.progress * 100).toInt()}% - ${String.format("%.1f", progress.speedMbps)} MB/s",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                IconButton(onClick = { if (progress.isPaused) onResume() else onPause() }) {
                    Icon(
                        if (progress.isPaused) Icons.Default.PlayArrow else Icons.Default.Pause,
                        contentDescription = if (progress.isPaused) "Resume" else "Pause"
                    )
                }
            }
            Spacer(modifier = Modifier.height(8.dp))
            LinearProgressIndicator(
                progress = { progress.progress.toFloat() },
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Composable
private fun QueueItemCard(
    clip: ClipResponse,
    isReceiving: Boolean,
    onClick: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = !isReceiving) { onClick() }
    ) {
        Row(
            modifier = Modifier.padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                if (clip.type == "text") Icons.Default.ContentCopy else Icons.Default.Description,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(24.dp)
            )
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(clip.filename, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    formatSize(clip.sizeBytes),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            if (isReceiving) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            }
        }
    }
}

private fun formatSize(bytes: Long): String {
    return when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> "${bytes / 1024} KB"
        bytes < 1024 * 1024 * 1024 -> String.format("%.1f MB", bytes / (1024.0 * 1024.0))
        else -> String.format("%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0))
    }
}
