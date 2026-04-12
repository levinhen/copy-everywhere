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
import android.provider.MediaStore
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.copyeverywhere.app.MainActivity
import com.copyeverywhere.app.R
import com.copyeverywhere.app.data.ApiClient
import com.copyeverywhere.app.data.ClipAlreadyConsumedException
import com.copyeverywhere.app.data.ConfigStore
import com.copyeverywhere.app.data.SseClient
import com.copyeverywhere.app.data.TransferMode
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class CopyEverywhereService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var sseJob: Job? = null
    private lateinit var configStore: ConfigStore
    private val apiClient = ApiClient()
    private val sseClient = SseClient()

    override fun onCreate() {
        super.onCreate()
        instance = this
        configStore = ConfigStore(applicationContext)
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
                    // RFCOMM server will be started by US-062
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
        scope.cancel()
        super.onDestroy()
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
                updateServiceNotification("Not configured")
                return@launch
            }

            sseClient.connect(
                hostUrl = hostUrl,
                accessToken = accessToken,
                deviceId = deviceId,
                onEvent = { event -> handleSseEvent(event) },
                onConnected = { updateServiceNotification("Connected — listening for clips") },
                onDisconnected = { updateServiceNotification("Reconnecting...") }
            )
        }
    }

    fun stopSse() {
        sseJob?.cancel()
        sseJob = null
        updateServiceNotification("Disconnected")
    }

    /**
     * Switch between LAN and Bluetooth modes.
     * LAN: starts SSE + queue polling.
     * Bluetooth: stops SSE (RFCOMM server started by US-062).
     */
    fun switchMode(mode: TransferMode) {
        when (mode) {
            TransferMode.LanServer -> {
                // Stop Bluetooth (RFCOMM server stop — US-062)
                startSse()
                updateServiceNotification("LAN — Listening for clips...")
            }
            TransferMode.Bluetooth -> {
                stopSse()
                // Start RFCOMM server — US-062
                updateServiceNotification("Bluetooth — Waiting for connection...")
            }
        }
    }

    private suspend fun handleSseEvent(event: com.copyeverywhere.app.data.SseEvent) {
        if (event.event != "clip") return

        val clip = sseClient.parseClipEvent(event.data) ?: return
        Log.d(TAG, "SSE clip received: id=${clip.id}, type=${clip.type}")

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

        val shareIntent = if (savedUri != null) {
            Intent(Intent.ACTION_SEND).apply {
                type = contentType
                putExtra(Intent.EXTRA_STREAM, savedUri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        } else null

        val pendingShare = if (shareIntent != null) {
            val chooser = Intent.createChooser(shareIntent, "Share $filename")
            PendingIntent.getActivity(
                this, filename.hashCode(), chooser,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else null

        val builder = NotificationCompat.Builder(this, CHANNEL_TRANSFERS)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle("File received")
            .setContentText(filename)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)

        if (pendingShare != null) {
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
        val notification = NotificationCompat.Builder(this, CHANNEL_TRANSFERS)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()

        try {
            NotificationManagerCompat.from(this).notify(
                System.currentTimeMillis().toInt(),
                notification
            )
        } catch (e: SecurityException) {
            Log.w(TAG, "Cannot post notification — permission not granted", e)
        }
    }

    companion object {
        private const val TAG = "CopyEverywhereService"
        const val CHANNEL_SERVICE = "copyeverywhere_service"
        const val CHANNEL_TRANSFERS = "copyeverywhere_transfers"
        const val NOTIFICATION_ID_SERVICE = 1

        /** Live reference to the running service instance, or null if not running. */
        var instance: CopyEverywhereService? = null
            private set

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
    }
}
