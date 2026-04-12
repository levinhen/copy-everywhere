package com.copyeverywhere.app.data

import com.google.gson.Gson
import com.google.gson.annotations.SerializedName
import java.util.UUID

/**
 * Wire protocol for CopyEverywhere Bluetooth RFCOMM transfers.
 *
 * Format: newline-delimited JSON headers + raw content bytes.
 * - Handshake: {"app":"CopyEverywhere","version":"3.0"}\n
 * - Transfer:  {"type":"text|file","filename":"...","size":N}\n + <N raw bytes>
 */
object BluetoothProtocol {

    /** RFCOMM service UUID — must match macOS and Windows exactly. */
    val SERVICE_UUID: UUID = UUID.fromString("CE000001-1000-1000-8000-00805F9B34FB")

    /** SDP service name advertised over Bluetooth. */
    const val SERVICE_NAME = "CopyEverywhere"

    /** Protocol version string. */
    const val VERSION = "3.0"

    /** Handshake timeout in milliseconds. */
    const val HANDSHAKE_TIMEOUT_MS = 5000L

    /** Chunk size for streaming file sends over RFCOMM (16 KB). */
    const val SEND_CHUNK_SIZE = 16 * 1024

    /** Newline delimiter (0x0A). */
    const val DELIMITER = '\n'

    private val gson = Gson()

    /** Build the handshake JSON line (including trailing newline). */
    fun buildHandshake(): ByteArray {
        val json = gson.toJson(HandshakeMessage())
        return (json + DELIMITER).toByteArray(Charsets.UTF_8)
    }

    /** Parse a handshake JSON line. Returns null if invalid. */
    fun parseHandshake(line: String): HandshakeMessage? {
        return try {
            val msg = gson.fromJson(line.trim(), HandshakeMessage::class.java)
            if (msg.app == SERVICE_NAME && msg.version == VERSION) msg else null
        } catch (e: Exception) {
            null
        }
    }

    /** Build a transfer header JSON line (including trailing newline). */
    fun buildTransferHeader(header: BluetoothTransferHeader): ByteArray {
        val json = gson.toJson(header)
        return (json + DELIMITER).toByteArray(Charsets.UTF_8)
    }

    /** Parse a transfer header JSON line. Returns null if invalid. */
    fun parseTransferHeader(line: String): BluetoothTransferHeader? {
        return try {
            val header = gson.fromJson(line.trim(), BluetoothTransferHeader::class.java)
            @Suppress("SENSELESS_COMPARISON") // Gson can leave non-null fields null
            if (header.type != null && header.filename != null && header.size >= 0) header else null
        } catch (e: Exception) {
            null
        }
    }
}

data class HandshakeMessage(
    @SerializedName("app") val app: String = BluetoothProtocol.SERVICE_NAME,
    @SerializedName("version") val version: String = BluetoothProtocol.VERSION
)

enum class BluetoothContentType {
    @SerializedName("text") Text,
    @SerializedName("file") File
}

data class BluetoothTransferHeader(
    @SerializedName("type") val type: BluetoothContentType,
    @SerializedName("filename") val filename: String,
    @SerializedName("size") val size: Long
)

/** Payload received from a Bluetooth transfer. */
data class BluetoothPayload(
    val header: BluetoothTransferHeader,
    val data: ByteArray
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is BluetoothPayload) return false
        return header == other.header && data.contentEquals(other.data)
    }

    override fun hashCode(): Int {
        return 31 * header.hashCode() + data.contentHashCode()
    }
}
