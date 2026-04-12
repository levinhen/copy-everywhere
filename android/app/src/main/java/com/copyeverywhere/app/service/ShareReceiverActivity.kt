package com.copyeverywhere.app.service

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.copyeverywhere.app.data.ApiClient
import com.copyeverywhere.app.data.ConfigStore
import com.copyeverywhere.app.ui.theme.CopyEverywhereTheme
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class ShareReceiverActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val configStore = ConfigStore(applicationContext)
        val apiClient = ApiClient()

        setContent {
            CopyEverywhereTheme {
                ShareReceiverScreen(
                    intent = intent,
                    configStore = configStore,
                    apiClient = apiClient,
                    onDone = { finish() }
                )
            }
        }
    }
}

@Composable
private fun ShareReceiverScreen(
    intent: Intent,
    configStore: ConfigStore,
    apiClient: ApiClient,
    onDone: () -> Unit
) {
    val scope = rememberCoroutineScope()
    var status by remember { mutableStateOf<ShareStatus>(ShareStatus.Preparing) }
    var progress by remember { mutableDoubleStateOf(0.0) }
    var speedMbps by remember { mutableDoubleStateOf(0.0) }
    var fileName by remember { mutableStateOf("") }

    val context = androidx.compose.ui.platform.LocalContext.current
    val contentResolver = context.contentResolver

    LaunchedEffect(Unit) {
        scope.launch {
            try {
                val host = configStore.hostUrl.first()
                val token = configStore.getAccessToken()
                val sender = configStore.deviceId.first()
                val target = configStore.targetDeviceId.first()

                if (host.isEmpty()) {
                    status = ShareStatus.Error("Server not configured. Open CopyEverywhere and set up a server first.")
                    return@launch
                }

                when (intent.action) {
                    Intent.ACTION_SEND -> {
                        val textExtra = intent.getStringExtra(Intent.EXTRA_TEXT)
                        val streamUri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)

                        if (streamUri != null) {
                            sendFileUri(
                                apiClient, contentResolver, host, token, sender, target,
                                streamUri,
                                onFileName = { fileName = it },
                                onProgress = { progress = it },
                                onSpeed = { speedMbps = it },
                                onStatusChange = { status = it }
                            )
                        } else if (textExtra != null) {
                            status = ShareStatus.Uploading
                            fileName = "clipboard.txt"
                            apiClient.sendTextClip(host, token, textExtra, sender, target)
                            status = ShareStatus.Done
                        } else {
                            status = ShareStatus.Error("Nothing to share")
                        }
                    }
                    Intent.ACTION_SEND_MULTIPLE -> {
                        @Suppress("DEPRECATION")
                        val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                        if (uris.isNullOrEmpty()) {
                            status = ShareStatus.Error("No files to share")
                            return@launch
                        }
                        status = ShareStatus.Uploading
                        fileName = "${uris.size} files"
                        for ((index, uri) in uris.withIndex()) {
                            val name = ApiClient.getFileName(contentResolver, uri)
                            fileName = "${index + 1}/${uris.size}: $name"
                            progress = index.toDouble() / uris.size
                            sendFileUri(
                                apiClient, contentResolver, host, token, sender, target,
                                uri,
                                onFileName = { fileName = "${index + 1}/${uris.size}: $it" },
                                onProgress = { p ->
                                    progress = (index.toDouble() + p) / uris.size
                                },
                                onSpeed = { speedMbps = it },
                                onStatusChange = { s ->
                                    // Only propagate error, otherwise keep uploading
                                    if (s is ShareStatus.Error) status = s
                                }
                            )
                            if (status is ShareStatus.Error) return@launch
                        }
                        status = ShareStatus.Done
                    }
                    else -> {
                        status = ShareStatus.Error("Unsupported share action")
                    }
                }
            } catch (e: Exception) {
                status = ShareStatus.Error(e.message ?: "Upload failed")
            }
        }
    }

    // Auto-finish after success
    LaunchedEffect(status) {
        if (status is ShareStatus.Done) {
            kotlinx.coroutines.delay(1500)
            onDone()
        }
    }

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(24.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                text = "CopyEverywhere",
                style = MaterialTheme.typography.headlineSmall
            )

            Spacer(modifier = Modifier.height(24.dp))

            when (val s = status) {
                is ShareStatus.Preparing -> {
                    CircularProgressIndicator()
                    Spacer(modifier = Modifier.height(12.dp))
                    Text("Preparing...")
                }
                is ShareStatus.Uploading -> {
                    if (fileName.isNotEmpty()) {
                        Text(
                            text = fileName,
                            style = MaterialTheme.typography.bodyMedium,
                            maxLines = 2
                        )
                        Spacer(modifier = Modifier.height(12.dp))
                    }
                    LinearProgressIndicator(
                        progress = { progress.toFloat() },
                        modifier = Modifier.fillMaxWidth()
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "${(progress * 100).toInt()}%" +
                            if (speedMbps > 0) " • ${"%.1f".format(speedMbps)} MB/s" else "",
                        style = MaterialTheme.typography.bodySmall
                    )
                }
                is ShareStatus.Done -> {
                    Text(
                        text = "Sent!",
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.primary
                    )
                }
                is ShareStatus.Error -> {
                    Text(
                        text = s.message,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error
                    )
                    Spacer(modifier = Modifier.height(16.dp))
                    Button(onClick = onDone) {
                        Text("Close")
                    }
                }
            }
        }
    }
}

private suspend fun sendFileUri(
    apiClient: ApiClient,
    contentResolver: android.content.ContentResolver,
    host: String,
    token: String,
    sender: String,
    target: String,
    uri: Uri,
    onFileName: (String) -> Unit,
    onProgress: (Double) -> Unit,
    onSpeed: (Double) -> Unit,
    onStatusChange: (ShareStatus) -> Unit
) {
    val name = ApiClient.getFileName(contentResolver, uri)
    val size = ApiClient.getFileSize(contentResolver, uri)
    onFileName(name)
    onStatusChange(ShareStatus.Uploading)

    if (size >= CHUNKED_THRESHOLD) {
        // Chunked upload
        val state = apiClient.initChunkedUpload(host, token, contentResolver, uri, sender, target)
        kotlinx.coroutines.coroutineScope {
            val pJob = launch {
                state.progress.collect { p: Double -> onProgress(p) }
            }
            val sJob = launch {
                state.speedMbps.collect { s: Double -> onSpeed(s) }
            }
            apiClient.uploadChunks(host, token, contentResolver, uri, state)
            apiClient.completeChunkedUpload(host, token, state.uploadId)
            pJob.cancel()
            sJob.cancel()
        }
    } else {
        // Small file — no granular progress, just show indeterminate
        onProgress(0.0)
        apiClient.sendFileClip(host, token, contentResolver, uri, sender, target)
        onProgress(1.0)
    }
}

private const val CHUNKED_THRESHOLD = 50L * 1024 * 1024 // 50 MB

private sealed class ShareStatus {
    data object Preparing : ShareStatus()
    data object Uploading : ShareStatus()
    data object Done : ShareStatus()
    data class Error(val message: String) : ShareStatus()
}
