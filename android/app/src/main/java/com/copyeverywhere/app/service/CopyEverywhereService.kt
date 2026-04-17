package com.copyeverywhere.app.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.os.IBinder
import android.os.PowerManager
import android.provider.MediaStore
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.copyeverywhere.app.MainActivity
import com.copyeverywhere.app.R
import com.copyeverywhere.app.data.ApiClient
import com.copyeverywhere.app.data.BluetoothContentType
import com.copyeverywhere.app.data.BluetoothPayload
import com.copyeverywhere.app.data.BluetoothService
import com.copyeverywhere.app.data.BluetoothSession
import com.copyeverywhere.app.data.BluetoothTransferHeader
import com.copyeverywhere.app.data.ClipAlreadyConsumedException
import com.copyeverywhere.app.data.ConfigStore
import com.copyeverywhere.app.data.SseClient
import com.copyeverywhere.app.data.TransferMode
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

enum class LanReceiverStatus {
    Connected,
    Reconnecting,
    Unavailable
}

data class LanReceiverHealth(
    val status: LanReceiverStatus,
    val detail: String
)

class CopyEverywhereService : Service(), BluetoothService.Listener {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var sseJob: Job? = null
    private lateinit var configStore: ConfigStore
    private val apiClient = ApiClient()
    private val sseClient = SseClient()

    /** Bluetooth RFCOMM service — manages server and client connections. */
    var bluetoothService: BluetoothService? = null
        private set

    /** WakeLock held during active transfers to prevent CPU sleep. */
    private var wakeLock: PowerManager.WakeLock? = null
    private var wakeLockHolders = 0

    /** Bluetooth receive progress (0.0–1.0), observed by MainViewModel for UI. */
    private val _btReceiveProgress = MutableStateFlow<Double?>(null)
    val btReceiveProgress: StateFlow<Double?> = _btReceiveProgress.asStateFlow()

    /** Filename of the Bluetooth transfer currently being received. */
    private val _btReceiveFilename = MutableStateFlow<String?>(null)
    val btReceiveFilename: StateFlow<String?> = _btReceiveFilename.asStateFlow()

    override fun onCreate() {
        super.onCreate()
        instance = this
        configStore = ConfigStore(applicationContext)
        bluetoothService = BluetoothService(applicationContext).also {
            it.listener = this
        }
        createNotificationChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        scope.launch {
            val mode = configStore.transferMode.first()
            when (mode) {
                TransferMode.LanServer -> {
                    startForeground(NOTIFICATION_ID_SERVICE, buildServiceNotification("LAN — Listening for clips..."))
                    startSse()
                }
                TransferMode.Bluetooth -> {
                    startForeground(NOTIFICATION_ID_SERVICE, buildServiceNotification("Bluetooth — Waiting for connection..."))
                    startBluetoothServer()
                    autoReconnectBluetooth()
                }
            }
        }
        // Start immediately with a generic notification (coroutine updates it)
        startForeground(NOTIFICATION_ID_SERVICE, buildServiceNotification("Starting..."))
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        instance = null
        sseJob?.cancel()
        bluetoothService?.listener = null
        bluetoothService?.destroy()
        receiverHealth.value = LanReceiverHealth(
            status = LanReceiverStatus.Unavailable,
            detail = "Foreground service is not running"
        )
        releaseWakeLockFully()
        scope.cancel()
        super.onDestroy()
    }

    /**
     * Acquire a partial WakeLock to keep the CPU alive during an active transfer.
     * Supports nested calls — each [acquireWakeLock] must be matched by [releaseWakeLock].
     * The WakeLock auto-releases after 10 minutes as a safety net.
     */
    fun acquireWakeLock() {
        synchronized(this) {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "CopyEverywhere::TransferWakeLock"
                )
            }
            wakeLockHolders++
            if (wakeLockHolders == 1) {
                wakeLock?.acquire(10 * 60 * 1000L) // 10 min timeout safety net
                Log.d(TAG, "WakeLock acquired")
            }
        }
    }

    /** Release one hold on the WakeLock. When all holders release, the lock is freed. */
    fun releaseWakeLock() {
        synchronized(this) {
            if (wakeLockHolders > 0) {
                wakeLockHolders--
                if (wakeLockHolders == 0 && wakeLock?.isHeld == true) {
                    wakeLock?.release()
                    Log.d(TAG, "WakeLock released")
                }
            }
        }
    }

    private fun releaseWakeLockFully() {
        synchronized(this) {
            wakeLockHolders = 0
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
            wakeLock = null
        }
    }

    private fun createNotificationChannels() {
        val serviceChannel = NotificationChannel(
            CHANNEL_SERVICE,
            "CopyEverywhere Service",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Ongoing notification for the CopyEverywhere background service"
        }

        val transferChannel = NotificationChannel(
            CHANNEL_TRANSFERS,
            "Transfers",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Notifications for received clips and transfer status"
        }

        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(serviceChannel)
        nm.createNotificationChannel(transferChannel)
    }

    private fun buildServiceNotification(text: String): Notification {
        return buildServiceNotificationStatic(this, text)
    }

    private fun updateServiceNotification(text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIFICATION_ID_SERVICE, buildServiceNotification(text))
    }

    fun startSse() {
        sseJob?.cancel()
        sseJob = scope.launch {
            val hostUrl = configStore.hostUrl.first()
            val accessToken = configStore.getAccessToken()
            val deviceId = configStore.deviceId.first()

            if (hostUrl.isEmpty() || deviceId.isEmpty()) {
                updateLanReceiverHealth(
                    LanReceiverStatus.Unavailable,
                    "Configure host URL and device ID to enable LAN auto-receive"
                )
                return@launch
            }

            updateLanReceiverHealth(
                LanReceiverStatus.Reconnecting,
                "Connecting to LAN receiver channel..."
            )

            sseClient.connect(
                hostUrl = hostUrl,
                accessToken = accessToken,
                deviceId = deviceId,
                onEvent = { event -> handleSseEvent(event) },
                onConnected = {
                    updateLanReceiverHealth(
                        LanReceiverStatus.Connected,
                        "Connected and ready for targeted auto-delivery"
                    )
                },
                onDisconnected = { retryDelayMs, error ->
                    val retrySeconds = (retryDelayMs / 1000).coerceAtLeast(1)
                    val reason = error?.message?.takeIf { it.isNotBlank() } ?: "connection dropped"
                    updateLanReceiverHealth(
                        LanReceiverStatus.Reconnecting,
                        "Reconnecting in ${retrySeconds}s after $reason"
                    )
                }
            )
        }
    }

    fun stopSse() {
        sseJob?.cancel()
        sseJob = null
        updateLanReceiverHealth(
            LanReceiverStatus.Unavailable,
            "LAN receiver stopped"
        )
    }

    /**
     * Switch between LAN and Bluetooth modes.
     * LAN: stops RFCOMM server, starts SSE + queue polling.
     * Bluetooth: stops SSE, starts RFCOMM server + auto-reconnect.
     */
    fun switchMode(mode: TransferMode) {
        when (mode) {
            TransferMode.LanServer -> {
                stopBluetoothServer()
                updateLanReceiverHealth(
                    LanReceiverStatus.Reconnecting,
                    "Starting LAN receiver..."
                )
                startSse()
            }
            TransferMode.Bluetooth -> {
                stopSse()
                startBluetoothServer()
                updateServiceNotification("Bluetooth — Waiting for connection...")
                scope.launch { autoReconnectBluetooth() }
            }
        }
    }

    fun startBluetoothServer() {
        bluetoothService?.startServer()
    }

    fun stopBluetoothServer() {
        bluetoothService?.cancelReconnect()
        bluetoothService?.disconnectSession()
        bluetoothService?.stopServer()
    }

    /**
     * Attempt to auto-reconnect to the last-connected Bluetooth device.
     * Uses exponential backoff (2s → 4s → 8s → capped 30s), max 5 attempts.
     */
    private suspend fun autoReconnectBluetooth() {
        val bt = bluetoothService ?: return
        val lastAddress = configStore.lastConnectedBtAddress.first()
        if (lastAddress.isEmpty()) {
            Log.d(TAG, "No last-connected Bluetooth device to reconnect to")
            return
        }

        Log.d(TAG, "Auto-reconnecting to last Bluetooth device: $lastAddress")
        bt.autoReconnect(lastAddress) { status ->
            updateServiceNotification("Bluetooth — $status")
        }
    }

    // --- BluetoothService.Listener --- update notification on BT connection status changes

    override fun onSessionReady(session: BluetoothSession) {
        Log.d(TAG, "Bluetooth session ready with ${session.deviceName}")
        updateServiceNotification("Bluetooth — Connected to ${session.deviceName}")
    }

    override fun onSessionHandshakeFailed(session: BluetoothSession, error: Exception) {
        Log.w(TAG, "Bluetooth handshake failed: ${error.message}")
        updateServiceNotification("Bluetooth — Handshake failed")
    }

    override fun onTransferReceived(session: BluetoothSession, payload: BluetoothPayload) {
        Log.d(TAG, "Bluetooth transfer received: type=${payload.header.type}, filename=${payload.header.filename}, size=${payload.data.size}")
        // Clear receive progress
        _btReceiveProgress.value = null
        _btReceiveFilename.value = null
        releaseWakeLock() // Release the lock acquired in onReceiveProgress

        // Verify size matches header
        if (payload.data.size.toLong() != payload.header.size) {
            Log.w(TAG, "BT receive size mismatch: header=${payload.header.size}, actual=${payload.data.size}")
            showTransferNotification("Receive failed", "File size mismatch")
            return
        }

        when (payload.header.type) {
            BluetoothContentType.Text -> handleTextClip(payload.data)
            BluetoothContentType.File -> {
                val mimeType = ApiClient.guessMimeType(payload.header.filename)
                handleFileClip(payload.header.filename, mimeType, payload.data)
            }
        }
    }

    override fun onReceiveProgress(session: BluetoothSession, progress: Double, header: BluetoothTransferHeader) {
        // Acquire WakeLock on first progress report (start of transfer)
        if (_btReceiveProgress.value == null) {
            acquireWakeLock()
        }
        _btReceiveProgress.value = progress
        _btReceiveFilename.value = header.filename
    }

    override fun onReceiveFailed(session: BluetoothSession, error: Exception) {
        Log.w(TAG, "Bluetooth receive failed: ${error.message}")
        _btReceiveProgress.value = null
        _btReceiveFilename.value = null
        releaseWakeLock()
        showTransferNotification("Receive failed", error.message ?: "Unknown error")
    }

    override fun onSessionDisconnected(session: BluetoothSession) {
        Log.d(TAG, "Bluetooth session disconnected from ${session.deviceName}")
        updateServiceNotification("Bluetooth — Disconnected")
    }

    private suspend fun handleSseEvent(event: com.copyeverywhere.app.data.SseEvent) {
        if (event.event != "clip") return

        val clip = sseClient.parseClipEvent(event.data) ?: return
        Log.d(TAG, "SSE clip received: id=${clip.id}, type=${clip.type}")

        acquireWakeLock()
        try {
            val hostUrl = configStore.hostUrl.first()
            val accessToken = configStore.getAccessToken()
            val downloaded = apiClient.downloadClipRaw(hostUrl, accessToken, clip.id)

            when (downloaded.metadata.type) {
                "text" -> handleTextClip(downloaded.bytes)
                else -> handleFileClip(downloaded.metadata.filename, downloaded.contentType, downloaded.bytes)
            }
        } catch (e: ClipAlreadyConsumedException) {
            Log.d(TAG, "Clip already consumed: ${clip.id}")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to process clip ${clip.id}", e)
            showTransferNotification("Receive failed", "Could not download clip: ${e.message}")
        } finally {
            releaseWakeLock()
        }
    }

    private fun handleTextClip(bytes: ByteArray) {
        val text = String(bytes, Charsets.UTF_8)
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("CopyEverywhere", text))
        showTransferNotification("Text received", "Copied to clipboard")
    }

    private fun handleFileClip(filename: String, contentType: String, bytes: ByteArray) {
        val savedUri = saveToDownloads(filename, contentType, bytes)

        val builder = NotificationCompat.Builder(this, CHANNEL_TRANSFERS)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle("File received")
            .setContentText(filename)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)

        if (savedUri != null) {
            // Open action — tapping the notification opens the file
            val openIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(savedUri, contentType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val pendingOpen = PendingIntent.getActivity(
                this, filename.hashCode(), openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            builder.setContentIntent(pendingOpen)
            builder.addAction(0, "Open", pendingOpen)

            // Share action
            val shareIntent = Intent(Intent.ACTION_SEND).apply {
                type = contentType
                putExtra(Intent.EXTRA_STREAM, savedUri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(shareIntent, "Share $filename")
            val pendingShare = PendingIntent.getActivity(
                this, filename.hashCode() + 1, chooser,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            builder.addAction(0, "Share", pendingShare)
        }

        try {
            NotificationManagerCompat.from(this).notify(
                filename.hashCode(),
                builder.build()
            )
        } catch (e: SecurityException) {
            Log.w(TAG, "Cannot post notification — permission not granted", e)
        }
    }

    private fun saveToDownloads(filename: String, mimeType: String, bytes: ByteArray): android.net.Uri? {
        val contentValues = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, filename)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
        }

        val resolver = contentResolver
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
        if (uri != null) {
            resolver.openOutputStream(uri)?.use { it.write(bytes) }
        }
        return uri
    }

    private fun showTransferNotification(title: String, text: String) {
        showTransferNotificationStatic(this, title, text)
    }

    private fun updateLanReceiverHealth(status: LanReceiverStatus, detail: String) {
        receiverHealth.value = LanReceiverHealth(status, detail)
        val headline = when (status) {
            LanReceiverStatus.Connected -> "LAN receiver connected"
            LanReceiverStatus.Reconnecting -> "LAN receiver reconnecting"
            LanReceiverStatus.Unavailable -> "LAN receiver unavailable"
        }
        updateServiceNotification("$headline — $detail")
    }

    companion object {
        private const val TAG = "CopyEverywhereService"
        const val CHANNEL_SERVICE = "copyeverywhere_service"
        const val CHANNEL_TRANSFERS = "copyeverywhere_transfers"
        const val NOTIFICATION_ID_SERVICE = 1

        /** Live reference to the running service instance, or null if not running. */
        var instance: CopyEverywhereService? = null
            private set

        val receiverHealth = MutableStateFlow(
            LanReceiverHealth(
                status = LanReceiverStatus.Unavailable,
                detail = "Foreground service is not running"
            )
        )

        fun start(context: Context) {
            val intent = Intent(context, CopyEverywhereService::class.java)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, CopyEverywhereService::class.java)
            context.stopService(intent)
        }

        /**
         * Build the ongoing service notification. Exposed as static so the
         * ClipboardTrampolineActivity can update the notification after sending.
         */
        fun buildServiceNotificationStatic(context: Context, text: String): Notification {
            val openIntent = Intent(context, MainActivity::class.java)
            val openPendingIntent = PendingIntent.getActivity(
                context, 0, openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            // "Tap to send clipboard" action launches the trampoline activity
            // (Android 10+ restricts clipboard read to foreground activities)
            val sendIntent = Intent(context, ClipboardTrampolineActivity::class.java)
            val sendPendingIntent = PendingIntent.getActivity(
                context, 1, sendIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            return NotificationCompat.Builder(context, CHANNEL_SERVICE)
                .setSmallIcon(R.drawable.ic_launcher_foreground)
                .setContentTitle("CopyEverywhere")
                .setContentText(text)
                .setContentIntent(openPendingIntent)
                .addAction(0, "Send clipboard", sendPendingIntent)
                .setOngoing(true)
                .setSilent(true)
                .build()
        }

        /**
         * Post a transfer notification (send success, send error, receive error).
         * Exposed as static so activities and view models can post transfer
         * notifications without a service reference.
         */
        fun showTransferNotificationStatic(context: Context, title: String, text: String) {
            val notification = NotificationCompat.Builder(context, CHANNEL_TRANSFERS)
                .setSmallIcon(R.drawable.ic_launcher_foreground)
                .setContentTitle(title)
                .setContentText(text)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()

            try {
                NotificationManagerCompat.from(context).notify(
                    System.currentTimeMillis().toInt(),
                    notification
                )
            } catch (e: SecurityException) {
                Log.w(TAG, "Cannot post notification — permission not granted", e)
            }
        }
    }

}
