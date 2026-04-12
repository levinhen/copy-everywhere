package com.copyeverywhere.app.data

import com.google.gson.Gson
import com.google.gson.annotations.SerializedName
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
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
}
