package com.copyeverywhere.app.ui.main

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import android.widget.Toast
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.copyeverywhere.app.data.ApiClient
import com.copyeverywhere.app.data.ChunkedUploadState
import com.copyeverywhere.app.data.ClipAlreadyConsumedException
import com.copyeverywhere.app.data.ClipResponse
import com.copyeverywhere.app.data.ConfigStore
import com.copyeverywhere.app.data.TransferMode
import com.copyeverywhere.app.data.isTargetedFallback
import com.copyeverywhere.app.service.CopyEverywhereService
import com.copyeverywhere.app.service.LanReceiverHealth
import com.copyeverywhere.app.service.LanReceiverStatus
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class MainViewModel(application: Application) : AndroidViewModel(application) {

    private val configStore = ConfigStore(application)
    private val apiClient = ApiClient()

    val hostUrl: StateFlow<String> = configStore.hostUrl
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")
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
    val targetedFallbackNotice: StateFlow<String?> = CopyEverywhereService.targetedFallbackNotice
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    private val _textInput = MutableStateFlow("")
    val textInput: StateFlow<String> = _textInput.asStateFlow()

    private val _sendStatus = MutableStateFlow<SendStatus>(SendStatus.Idle)
    val sendStatus: StateFlow<SendStatus> = _sendStatus.asStateFlow()

    private val _queue = MutableStateFlow<List<ClipResponse>>(emptyList())
    val queue: StateFlow<List<ClipResponse>> = _queue.asStateFlow()

    private val _uploadProgress = MutableStateFlow<UploadProgress?>(null)
    val uploadProgress: StateFlow<UploadProgress?> = _uploadProgress.asStateFlow()

    private val _receiveStatus = MutableStateFlow<ReceiveStatus>(ReceiveStatus.Idle)
    val receiveStatus: StateFlow<ReceiveStatus> = _receiveStatus.asStateFlow()

    /** Bluetooth receive progress (0.0–1.0), read from the foreground service. */
    private val _btReceiveProgress = MutableStateFlow<Double?>(null)
    val btReceiveProgress: StateFlow<Double?> = _btReceiveProgress.asStateFlow()

    /** Filename of the Bluetooth transfer currently being received. */
    private val _btReceiveFilename = MutableStateFlow<String?>(null)
    val btReceiveFilename: StateFlow<String?> = _btReceiveFilename.asStateFlow()

    private var btReceivePollingJob: Job? = null
    private var queuePollingJob: Job? = null
    private var chunkedUploadState: ChunkedUploadState? = null
    private var chunkedUploadUri: Uri? = null

    fun updateTextInput(text: String) {
        _textInput.value = text
    }

    fun sendText() {
        val text = _textInput.value.trim()
        if (text.isEmpty()) return

        viewModelScope.launch {
            _sendStatus.value = SendStatus.Sending
            try {
                val currentMode = configStore.transferMode.first()
                if (currentMode == TransferMode.Bluetooth) {
                    val session = CopyEverywhereService.instance?.bluetoothService?.activeSession
                    if (session == null || !session.isHandshakeComplete) {
                        _sendStatus.value = SendStatus.Error("No Bluetooth device connected")
                        showErrorNotification("No Bluetooth device connected")
                        delay(3000)
                        _sendStatus.value = SendStatus.Idle
                        return@launch
                    }
                    session.sendText(text).collect { /* progress not shown for text */ }
                } else {
                    val host = configStore.hostUrl.first().trim()
                    val token = configStore.getAccessToken()
                    val sender = configStore.deviceId.first()
                    val target = configStore.targetDeviceId.first()
                    if (!host.startsWith("http://") && !host.startsWith("https://")) {
                        throw IllegalStateException("Host URL must start with http:// or https://")
                    }
                    apiClient.sendTextClip(host, token, text, sender, target)
                }
                _textInput.value = ""
                _sendStatus.value = SendStatus.Success
                Toast.makeText(getApplication(), successToastMessage(isFile = false), Toast.LENGTH_SHORT).show()
                delay(2000)
                _sendStatus.value = SendStatus.Idle
            } catch (e: Exception) {
                Log.e(TAG, "sendText failed", e)
                _sendStatus.value = SendStatus.Error(e.message ?: "Send failed")
                showErrorNotification(e.message ?: "Send failed")
                delay(3000)
                _sendStatus.value = SendStatus.Idle
            }
        }
    }

    fun sendFile(uri: Uri) {
        viewModelScope.launch {
            val currentMode = configStore.transferMode.first()
            if (currentMode == TransferMode.Bluetooth) {
                sendFileBluetooth(uri)
            } else {
                val contentResolver = getApplication<Application>().contentResolver
                val fileSize = ApiClient.getFileSize(contentResolver, uri)
                val fileName = ApiClient.getFileName(contentResolver, uri)

                if (fileSize >= CHUNKED_THRESHOLD) {
                    startChunkedUpload(uri, fileName)
                } else {
                    sendSmallFile(uri, fileName)
                }
            }
        }
    }

    private suspend fun sendFileBluetooth(uri: Uri) {
        val session = CopyEverywhereService.instance?.bluetoothService?.activeSession
        if (session == null || !session.isHandshakeComplete) {
            _sendStatus.value = SendStatus.Error("No Bluetooth device connected")
            showErrorNotification("No Bluetooth device connected")
            delay(3000)
            _sendStatus.value = SendStatus.Idle
            return
        }

        val contentResolver = getApplication<Application>().contentResolver
        val fileName = ApiClient.getFileName(contentResolver, uri)
        val fileSize = ApiClient.getFileSize(contentResolver, uri)

        _uploadProgress.value = UploadProgress(
            fileName = fileName,
            progress = 0.0,
            speedMbps = 0.0,
            isPaused = false
        )

        try {
            val startTime = System.currentTimeMillis()
            session.sendFile(getApplication<Application>(), uri).collect { p ->
                val elapsed = (System.currentTimeMillis() - startTime) / 1000.0
                val sentBytes = (p * fileSize)
                val speed = if (elapsed > 0) sentBytes / elapsed / (1024 * 1024) else 0.0
                _uploadProgress.value = _uploadProgress.value?.copy(progress = p, speedMbps = speed)
            }
            _uploadProgress.value = null
            _sendStatus.value = SendStatus.Success
            Toast.makeText(getApplication(), "Bluetooth direct file sent", Toast.LENGTH_SHORT).show()
            delay(2000)
            _sendStatus.value = SendStatus.Idle
        } catch (e: Exception) {
            _uploadProgress.value = null
            _sendStatus.value = SendStatus.Error(e.message ?: "Bluetooth send failed")
            showErrorNotification(e.message ?: "Bluetooth send failed")
            delay(3000)
            _sendStatus.value = SendStatus.Idle
        }
    }

    private suspend fun sendSmallFile(uri: Uri, fileName: String) {
        _sendStatus.value = SendStatus.Sending
        try {
            val contentResolver = getApplication<Application>().contentResolver
            val host = configStore.hostUrl.first().trim()
            val token = configStore.getAccessToken()
            val sender = configStore.deviceId.first()
            val target = configStore.targetDeviceId.first()
            if (!host.startsWith("http://") && !host.startsWith("https://")) {
                throw IllegalStateException("Host URL must start with http:// or https://")
            }
            apiClient.sendFileClip(host, token, contentResolver, uri, sender, target)
            _sendStatus.value = SendStatus.Success
            Toast.makeText(getApplication(), successToastMessage(isFile = true), Toast.LENGTH_SHORT).show()
            delay(2000)
            _sendStatus.value = SendStatus.Idle
        } catch (e: Exception) {
            Log.e(TAG, "sendSmallFile failed", e)
            _sendStatus.value = SendStatus.Error(e.message ?: "Upload failed")
            showErrorNotification(e.message ?: "Upload failed")
            delay(3000)
            _sendStatus.value = SendStatus.Idle
        }
    }

    private suspend fun startChunkedUpload(uri: Uri, fileName: String) {
        _uploadProgress.value = UploadProgress(fileName = fileName, progress = 0.0, speedMbps = 0.0, isPaused = false)
        try {
            val contentResolver = getApplication<Application>().contentResolver
            val host = configStore.hostUrl.first().trim()
            val token = configStore.getAccessToken()
            val sender = configStore.deviceId.first()
            val target = configStore.targetDeviceId.first()
            if (!host.startsWith("http://") && !host.startsWith("https://")) {
                throw IllegalStateException("Host URL must start with http:// or https://")
            }

            val state = apiClient.initChunkedUpload(host, token, contentResolver, uri, sender, target)
            chunkedUploadState = state
            chunkedUploadUri = uri

            // Collect progress in background
            val progressJob = viewModelScope.launch {
                state.progress.collect { p ->
                    _uploadProgress.value = _uploadProgress.value?.copy(progress = p)
                }
            }
            val speedJob = viewModelScope.launch {
                state.speedMbps.collect { s ->
                    _uploadProgress.value = _uploadProgress.value?.copy(speedMbps = s)
                }
            }

            state.job = viewModelScope.launch {
                try {
                    apiClient.uploadChunks(host, token, contentResolver, uri, state)
                    apiClient.completeChunkedUpload(host, token, state.uploadId)
                    _uploadProgress.value = null
                    chunkedUploadState = null
                    chunkedUploadUri = null
                    _sendStatus.value = SendStatus.Success
                    Toast.makeText(getApplication(), successToastMessage(isFile = true), Toast.LENGTH_SHORT).show()
                    delay(2000)
                    _sendStatus.value = SendStatus.Idle
                } catch (e: kotlinx.coroutines.CancellationException) {
                    // Paused — don't clear state
                    throw e
                } catch (e: Exception) {
                    _uploadProgress.value = null
                    chunkedUploadState = null
                    chunkedUploadUri = null
                    _sendStatus.value = SendStatus.Error(e.message ?: "Upload failed")
                    showErrorNotification(e.message ?: "Upload failed")
                    delay(3000)
                    _sendStatus.value = SendStatus.Idle
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "startChunkedUpload failed", e)
            _uploadProgress.value = null
            _sendStatus.value = SendStatus.Error(e.message ?: "Upload init failed")
            showErrorNotification(e.message ?: "Upload init failed")
            delay(3000)
            _sendStatus.value = SendStatus.Idle
        }
    }

    fun pauseUpload() {
        val state = chunkedUploadState ?: return
        state.job?.cancel()
        state.job = null
        _uploadProgress.value = _uploadProgress.value?.copy(isPaused = true)
    }

    fun resumeUpload() {
        val state = chunkedUploadState ?: return
        val uri = chunkedUploadUri ?: return

        _uploadProgress.value = _uploadProgress.value?.copy(isPaused = false)

        viewModelScope.launch {
            try {
                val host = hostUrl.value
                val token = configStore.getAccessToken()
                val contentResolver = getApplication<Application>().contentResolver

                apiClient.resumeChunkedUpload(host, token, state)

                state.job = viewModelScope.launch {
                    try {
                        apiClient.uploadChunks(host, token, contentResolver, uri, state)
                        apiClient.completeChunkedUpload(host, token, state.uploadId)
                        _uploadProgress.value = null
                        chunkedUploadState = null
                        chunkedUploadUri = null
                        _sendStatus.value = SendStatus.Success
                        Toast.makeText(getApplication(), successToastMessage(isFile = true), Toast.LENGTH_SHORT).show()
                        delay(2000)
                        _sendStatus.value = SendStatus.Idle
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        _uploadProgress.value = null
                        chunkedUploadState = null
                        chunkedUploadUri = null
                        _sendStatus.value = SendStatus.Error(e.message ?: "Upload failed")
                        showErrorNotification(e.message ?: "Upload failed")
                        delay(3000)
                        _sendStatus.value = SendStatus.Idle
                    }
                }
            } catch (e: Exception) {
                _sendStatus.value = SendStatus.Error(e.message ?: "Resume failed")
                showErrorNotification(e.message ?: "Resume failed")
            }
        }
    }

    fun startQueuePolling() {
        queuePollingJob?.cancel()
        // Only poll queue in LAN mode
        if (transferMode.value != TransferMode.LanServer) return
        queuePollingJob = viewModelScope.launch {
            while (true) {
                refreshQueue()
                delay(5000)
            }
        }
    }

    fun stopQueuePolling() {
        queuePollingJob?.cancel()
        queuePollingJob = null
    }

    /** Start observing Bluetooth receive progress from the foreground service. */
    fun startBtReceiveObserving() {
        btReceivePollingJob?.cancel()
        if (transferMode.value != TransferMode.Bluetooth) return
        btReceivePollingJob = viewModelScope.launch {
            val service = CopyEverywhereService.instance ?: return@launch
            launch { service.btReceiveProgress.collect { _btReceiveProgress.value = it } }
            launch { service.btReceiveFilename.collect { _btReceiveFilename.value = it } }
        }
    }

    fun stopBtReceiveObserving() {
        btReceivePollingJob?.cancel()
        btReceivePollingJob = null
        _btReceiveProgress.value = null
        _btReceiveFilename.value = null
    }

    private suspend fun refreshQueue() {
        try {
            val host = configStore.hostUrl.first()
            val token = configStore.getAccessToken()
            val device = configStore.deviceId.first()
            if (host.isNotEmpty() && device.isNotEmpty()) {
                _queue.value = apiClient.fetchQueue(host, token, device)
            }
        } catch (_: Exception) {
            // Silently fail — queue refresh is non-critical
        }
    }

    fun receiveQueueItem(clip: ClipResponse) {
        viewModelScope.launch {
            _receiveStatus.value = ReceiveStatus.Receiving(clip.id)
            try {
                val host = configStore.hostUrl.first()
                val token = configStore.getAccessToken()
                val device = configStore.deviceId.first()
                val downloaded = apiClient.downloadClipRaw(host, token, clip.id, deviceId = device)

                when (downloaded.metadata.type) {
                    "text" -> {
                        val text = String(downloaded.bytes, Charsets.UTF_8)
                        val clipboard = getApplication<Application>().getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.setPrimaryClip(ClipData.newPlainText("CopyEverywhere", text))
                        Toast.makeText(getApplication(), "Copied to clipboard", Toast.LENGTH_SHORT).show()
                    }
                    else -> {
                        saveToDownloads(downloaded.metadata.filename, downloaded.contentType, downloaded.bytes)
                        Toast.makeText(getApplication(), "Saved to Downloads: ${downloaded.metadata.filename}", Toast.LENGTH_SHORT).show()
                    }
                }

                // Remove from queue
                _queue.value = _queue.value.filter { it.id != clip.id }
                if (clip.isTargetedFallback()) {
                    CopyEverywhereService.targetedFallbackNotice.value = null
                }
                _receiveStatus.value = ReceiveStatus.Idle
            } catch (e: ClipAlreadyConsumedException) {
                _queue.value = _queue.value.filter { it.id != clip.id }
                if (clip.isTargetedFallback()) {
                    CopyEverywhereService.targetedFallbackNotice.value = null
                }
                _receiveStatus.value = ReceiveStatus.Idle
                Toast.makeText(getApplication(), "Already consumed", Toast.LENGTH_SHORT).show()
            } catch (e: Exception) {
                _receiveStatus.value = ReceiveStatus.Error(e.message ?: "Receive failed")
                showErrorNotification(e.message ?: "Receive failed")
                delay(3000)
                _receiveStatus.value = ReceiveStatus.Idle
            }
        }
    }

    private fun showErrorNotification(message: String) {
        CopyEverywhereService.showTransferNotificationStatic(
            getApplication(), "Transfer error", message
        )
    }

    fun dismissTargetedFallbackNotice() {
        CopyEverywhereService.targetedFallbackNotice.value = null
    }

    private fun successToastMessage(isFile: Boolean): String {
        return when {
            transferMode.value == TransferMode.Bluetooth ->
                if (isFile) "Bluetooth direct file sent" else "Bluetooth direct send complete"
            targetDeviceId.value.isBlank() ->
                if (isFile) "Queue mode file ready" else "Queue mode send ready"
            else ->
                if (isFile) "Targeted auto-delivery file sent" else "Targeted auto-delivery send ready"
        }
    }

    private fun saveToDownloads(filename: String, mimeType: String, bytes: ByteArray) {
        val contentValues = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, filename)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
        }
        val resolver = getApplication<Application>().contentResolver
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
        if (uri != null) {
            resolver.openOutputStream(uri)?.use { it.write(bytes) }
        }
    }

    companion object {
        private const val TAG = "MainViewModel"
        private const val CHUNKED_THRESHOLD = 50L * 1024 * 1024 // 50 MB
    }
}

sealed class SendStatus {
    data object Idle : SendStatus()
    data object Sending : SendStatus()
    data object Success : SendStatus()
    data class Error(val message: String) : SendStatus()
}

sealed class ReceiveStatus {
    data object Idle : ReceiveStatus()
    data class Receiving(val clipId: String) : ReceiveStatus()
    data class Error(val message: String) : ReceiveStatus()
}

data class UploadProgress(
    val fileName: String,
    val progress: Double,
    val speedMbps: Double,
    val isPaused: Boolean
)
