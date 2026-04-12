package com.copyeverywhere.app.service

import android.app.NotificationManager
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.copyeverywhere.app.R
import com.copyeverywhere.app.data.ApiClient
import com.copyeverywhere.app.data.ConfigStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Transparent activity trampoline for reading the clipboard from a notification action.
 * Android 10+ restricts clipboard reads to foreground activities, so the background
 * service cannot read ClipboardManager directly. This activity launches in the foreground,
 * reads the clipboard, sends the text, and finishes immediately.
 */
class ClipboardTrampolineActivity : ComponentActivity() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboard.primaryClip

        if (clip == null || clip.itemCount == 0) {
            Toast.makeText(this, "Clipboard is empty", Toast.LENGTH_SHORT).show()
            finish()
            return
        }

        val text = clip.getItemAt(0).coerceToText(this)?.toString()
        if (text.isNullOrEmpty()) {
            Toast.makeText(this, "Clipboard is empty", Toast.LENGTH_SHORT).show()
            finish()
            return
        }

        val configStore = ConfigStore(applicationContext)
        val apiClient = ApiClient()

        scope.launch {
            try {
                val hostUrl = configStore.hostUrl.first()
                val accessToken = configStore.getAccessToken()
                val senderDeviceId = configStore.deviceId.first()
                val targetDeviceId = configStore.targetDeviceId.first()

                if (hostUrl.isEmpty()) {
                    Toast.makeText(this@ClipboardTrampolineActivity, "Not configured", Toast.LENGTH_SHORT).show()
                    finish()
                    return@launch
                }

                apiClient.sendTextClip(hostUrl, accessToken, text, senderDeviceId, targetDeviceId)

                // Update service notification briefly to show success
                updateServiceNotification("Sent!")
                Toast.makeText(this@ClipboardTrampolineActivity, "Sent!", Toast.LENGTH_SHORT).show()

                // Reset notification after a delay
                kotlinx.coroutines.delay(2000)
                updateServiceNotification("Listening for clips...")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send clipboard", e)
                val msg = "Send failed: ${e.message}"
                Toast.makeText(this@ClipboardTrampolineActivity, msg, Toast.LENGTH_SHORT).show()
                updateServiceNotification(msg)

                kotlinx.coroutines.delay(3000)
                updateServiceNotification("Listening for clips...")
            } finally {
                finish()
            }
        }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun updateServiceNotification(text: String) {
        val notification = CopyEverywhereService.buildServiceNotificationStatic(this, text)
        try {
            NotificationManagerCompat.from(this).notify(
                CopyEverywhereService.NOTIFICATION_ID_SERVICE,
                notification
            )
        } catch (e: SecurityException) {
            Log.w(TAG, "Cannot update notification", e)
        }
    }

    companion object {
        private const val TAG = "ClipboardTrampoline"
    }
}
