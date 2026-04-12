package com.copyeverywhere.app.data

import com.google.gson.Gson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit

data class SseEvent(
    val event: String,
    val data: String
)

class SseClient {

    private val gson = Gson()

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS) // infinite read timeout for SSE
        .writeTimeout(10, TimeUnit.SECONDS)
        .retryOnConnectionFailure(false)
        .build()

    /**
     * Connect to the SSE stream and invoke [onEvent] for each received event.
     * Reconnects with exponential backoff on failure.
     * This function never returns normally — cancel the coroutine to stop.
     */
    suspend fun connect(
        hostUrl: String,
        accessToken: String,
        deviceId: String,
        onEvent: suspend (SseEvent) -> Unit,
        onConnected: (() -> Unit)? = null,
        onDisconnected: (() -> Unit)? = null
    ): Unit = withContext(Dispatchers.IO) {
        var backoffMs = INITIAL_BACKOFF_MS

        while (true) {
            currentCoroutineContext().ensureActive()

            try {
                val url = "${hostUrl.trimEnd('/')}/api/v1/devices/$deviceId/stream"
                val requestBuilder = Request.Builder().url(url)
                if (accessToken.isNotEmpty()) {
                    requestBuilder.addHeader("Authorization", "Bearer $accessToken")
                }
                requestBuilder.addHeader("Accept", "text/event-stream")
                val request = requestBuilder.get().build()

                val response = client.newCall(request).execute()
                if (!response.isSuccessful) {
                    response.close()
                    throw IOException("SSE connect failed: ${response.code}")
                }

                // Connected successfully — reset backoff
                backoffMs = INITIAL_BACKOFF_MS
                onConnected?.invoke()

                val body = response.body ?: throw IOException("Empty SSE response body")
                val reader = BufferedReader(InputStreamReader(body.byteStream(), Charsets.UTF_8))

                try {
                    var currentEvent = ""
                    var currentData = StringBuilder()

                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val line = reader.readLine() ?: break // connection closed

                        if (line.isEmpty()) {
                            // Empty line = event boundary
                            if (currentEvent.isNotEmpty() || currentData.isNotEmpty()) {
                                onEvent(SseEvent(currentEvent, currentData.toString().trim()))
                                currentEvent = ""
                                currentData = StringBuilder()
                            }
                        } else if (line.startsWith("event:")) {
                            currentEvent = line.removePrefix("event:").trim()
                        } else if (line.startsWith("data:")) {
                            if (currentData.isNotEmpty()) currentData.append("\n")
                            currentData.append(line.removePrefix("data:").trim())
                        }
                        // Ignore comments (lines starting with :) and unknown fields
                    }
                } finally {
                    reader.close()
                    response.close()
                }
            } catch (e: Exception) {
                currentCoroutineContext().ensureActive()
                onDisconnected?.invoke()
            }

            // Exponential backoff before reconnect
            delay(backoffMs)
            backoffMs = (backoffMs * 2).coerceAtMost(MAX_BACKOFF_MS)
        }
    }

    /**
     * Parse a clip event's data JSON into a ClipResponse.
     */
    fun parseClipEvent(data: String): ClipResponse? {
        return try {
            gson.fromJson(data, ClipResponse::class.java)
        } catch (e: Exception) {
            null
        }
    }

    companion object {
        private const val INITIAL_BACKOFF_MS = 1000L
        private const val MAX_BACKOFF_MS = 30_000L
    }
}
