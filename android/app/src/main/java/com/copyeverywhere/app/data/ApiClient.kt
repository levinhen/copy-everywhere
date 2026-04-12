package com.copyeverywhere.app.data

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import com.google.gson.Gson
import com.google.gson.annotations.SerializedName
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okio.BufferedSink
import okio.source
import java.io.IOException
import java.util.concurrent.TimeUnit

data class HealthResponse(
    val version: String = "",
    val uptime: String = "",
    val auth: Boolean = false,
    @SerializedName("storage_used_bytes") val storageUsedBytes: Long = 0,
    @SerializedName("clip_count") val clipCount: Int = 0
)

data class Device(
    @SerializedName("device_id") val deviceId: String,
    val name: String,
    val platform: String,
    @SerializedName("last_seen_at") val lastSeenAt: String? = null,
    @SerializedName("created_at") val createdAt: String? = null
)

data class RegisterRequest(
    val name: String,
    val platform: String
)

data class RegisterResponse(
    @SerializedName("device_id") val deviceId: String
)

data class ClipResponse(
    val id: String = "",
    val type: String = "",
    val filename: String = "",
    @SerializedName("size_bytes") val sizeBytes: Long = 0,
    @SerializedName("content_type") val contentType: String = "",
    @SerializedName("created_at") val createdAt: String = "",
    @SerializedName("sender_device_id") val senderDeviceId: String? = null,
    @SerializedName("target_device_id") val targetDeviceId: String? = null
)

class ApiClient {

    private val gson = Gson()
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private fun buildRequest(url: String, accessToken: String): Request.Builder {
        val builder = Request.Builder().url(url)
        if (accessToken.isNotEmpty()) {
            builder.addHeader("Authorization", "Bearer $accessToken")
        }
        return builder
    }

    data class HealthResult(
        val response: HealthResponse,
        val latencyMs: Long
    )

    suspend fun checkHealth(hostUrl: String, accessToken: String): HealthResult = withContext(Dispatchers.IO) {
        val url = "${hostUrl.trimEnd('/')}/health"
        val request = buildRequest(url, "").get().build() // health doesn't need auth
        val startTime = System.currentTimeMillis()
        val response = client.newCall(request).execute()
        val latencyMs = System.currentTimeMillis() - startTime
        if (!response.isSuccessful) {
            throw IOException("Health check failed: ${response.code}")
        }
        val body = response.body?.string() ?: throw IOException("Empty response")
        val healthResponse = gson.fromJson(body, HealthResponse::class.java)
        HealthResult(healthResponse, latencyMs)
    }

    suspend fun registerDevice(hostUrl: String, accessToken: String, name: String, platform: String = "android"): String = withContext(Dispatchers.IO) {
        val url = "${hostUrl.trimEnd('/')}/api/v1/devices/register"
        val json = gson.toJson(RegisterRequest(name, platform))
        val body = json.toRequestBody("application/json".toMediaType())
        val request = buildRequest(url, accessToken).post(body).build()
        val response = client.newCall(request).execute()
        if (!response.isSuccessful) {
            throw IOException("Device registration failed: ${response.code}")
        }
        val responseBody = response.body?.string() ?: throw IOException("Empty response")
        gson.fromJson(responseBody, RegisterResponse::class.java).deviceId
    }

    suspend fun listDevices(hostUrl: String, accessToken: String): List<Device> = withContext(Dispatchers.IO) {
        val url = "${hostUrl.trimEnd('/')}/api/v1/devices"
        val request = buildRequest(url, accessToken).get().build()
        val response = client.newCall(request).execute()
        if (!response.isSuccessful) {
            throw IOException("List devices failed: ${response.code}")
        }
        val body = response.body?.string() ?: throw IOException("Empty response")
        gson.fromJson(body, Array<Device>::class.java).toList()
    }

    /**
     * Send a text clip to the server.
     */
    suspend fun sendTextClip(
        hostUrl: String,
        accessToken: String,
        text: String,
        senderDeviceId: String,
        targetDeviceId: String
    ): ClipResponse = withContext(Dispatchers.IO) {
        val url = "${hostUrl.trimEnd('/')}/api/v1/clips"
        val textBytes = text.toByteArray(Charsets.UTF_8)
        val contentBody = textBytes.toRequestBody("text/plain".toMediaType())

        val multipart = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("type", "text")
            .addFormDataPart("content", "clipboard.txt", contentBody)
            .apply {
                if (senderDeviceId.isNotEmpty()) addFormDataPart("sender_device_id", senderDeviceId)
                if (targetDeviceId.isNotEmpty()) addFormDataPart("target_device_id", targetDeviceId)
            }
            .build()

        val request = buildRequest(url, accessToken).post(multipart).build()
        val response = client.newCall(request).execute()
        if (!response.isSuccessful) {
            throw IOException("Send text clip failed: ${response.code}")
        }
        val body = response.body?.string() ?: throw IOException("Empty response")
        gson.fromJson(body, ClipResponse::class.java)
    }

    /**
     * Send a file clip to the server, streaming from a content URI.
     * Only for files < 50 MB. Larger files should use chunked upload.
     */
    suspend fun sendFileClip(
        hostUrl: String,
        accessToken: String,
        contentResolver: ContentResolver,
        fileUri: Uri,
        senderDeviceId: String,
        targetDeviceId: String
    ): ClipResponse = withContext(Dispatchers.IO) {
        val url = "${hostUrl.trimEnd('/')}/api/v1/clips"

        val filename = getFileName(contentResolver, fileUri)
        val mimeType = contentResolver.getType(fileUri) ?: guessMimeType(filename)

        val streamBody = object : RequestBody() {
            override fun contentType() = mimeType.toMediaType()
            override fun contentLength(): Long = getFileSize(contentResolver, fileUri)
            override fun writeTo(sink: BufferedSink) {
                contentResolver.openInputStream(fileUri)?.use { inputStream ->
                    inputStream.source().use { source ->
                        sink.writeAll(source)
                    }
                } ?: throw IOException("Cannot open file URI: $fileUri")
            }
        }

        val clipType = if (mimeType.startsWith("image/")) "image" else "file"

        val multipart = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("type", clipType)
            .addFormDataPart("content", filename, streamBody)
            .apply {
                if (senderDeviceId.isNotEmpty()) addFormDataPart("sender_device_id", senderDeviceId)
                if (targetDeviceId.isNotEmpty()) addFormDataPart("target_device_id", targetDeviceId)
            }
            .build()

        val request = buildRequest(url, accessToken).post(multipart).build()
        val response = client.newCall(request).execute()
        if (!response.isSuccessful) {
            throw IOException("Send file clip failed: ${response.code}")
        }
        val body = response.body?.string() ?: throw IOException("Empty response")
        gson.fromJson(body, ClipResponse::class.java)
    }

    companion object {
        fun getFileName(contentResolver: ContentResolver, uri: Uri): String {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0) {
                        return cursor.getString(nameIndex)
                    }
                }
            }
            return uri.lastPathSegment ?: "unknown"
        }

        fun getFileSize(contentResolver: ContentResolver, uri: Uri): Long {
            contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0) {
                        return cursor.getLong(sizeIndex)
                    }
                }
            }
            return -1L
        }

        fun guessMimeType(filename: String): String {
            val ext = filename.substringAfterLast('.', "").lowercase()
            return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        }
    }
}
