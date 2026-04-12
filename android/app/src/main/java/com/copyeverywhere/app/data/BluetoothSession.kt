package com.copyeverywhere.app.data

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.net.Uri
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream

/**
 * Wraps a BluetoothSocket and implements the CopyEverywhere RFCOMM protocol:
 * handshake → header → content accumulation.
 */
class BluetoothSession(
    val socket: BluetoothSocket,
    val device: BluetoothDevice?
) {
    interface Listener {
        fun onHandshakeComplete(session: BluetoothSession)
        fun onHandshakeFailed(session: BluetoothSession, error: Exception)
        fun onTransferReceived(session: BluetoothSession, payload: BluetoothPayload)
        fun onReceiveProgress(session: BluetoothSession, progress: Double, header: BluetoothTransferHeader)
        fun onReceiveFailed(session: BluetoothSession, error: Exception)
        fun onDisconnected(session: BluetoothSession)
    }

    var listener: Listener? = null

    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null

    @Volatile
    var isHandshakeComplete = false
        private set

    @Volatile
    var isConnected = false
        private set

    val deviceName: String
        get() = try {
            device?.name ?: device?.address ?: "Unknown"
        } catch (_: SecurityException) {
            device?.address ?: "Unknown"
        }

    val deviceAddress: String
        get() = device?.address ?: "Unknown"

    /**
     * Start the session: perform handshake, then enter the receive loop.
     * Call from a coroutine on Dispatchers.IO.
     */
    suspend fun start() = withContext(Dispatchers.IO) {
        try {
            inputStream = BufferedInputStream(socket.inputStream)
            outputStream = socket.outputStream
            isConnected = true

            // Perform handshake with timeout
            val handshakeOk = withTimeoutOrNull(BluetoothProtocol.HANDSHAKE_TIMEOUT_MS) {
                performHandshake()
            }
            if (handshakeOk != true) {
                val error = BluetoothSessionException("Handshake timeout or failure")
                listener?.onHandshakeFailed(this@BluetoothSession, error)
                close()
                return@withContext
            }

            isHandshakeComplete = true
            listener?.onHandshakeComplete(this@BluetoothSession)

            // Enter receive loop
            receiveLoop()
        } catch (e: Exception) {
            if (isConnected) {
                Log.e(TAG, "Session error", e)
                if (!isHandshakeComplete) {
                    listener?.onHandshakeFailed(this@BluetoothSession, e)
                } else {
                    listener?.onReceiveFailed(this@BluetoothSession, e)
                }
            }
        } finally {
            isConnected = false
            isHandshakeComplete = false
            listener?.onDisconnected(this@BluetoothSession)
        }
    }

    /**
     * Send a text clip over the RFCOMM connection.
     * Returns a Flow of progress (0.0 to 1.0).
     */
    fun sendText(text: String): Flow<Double> = flow {
        val bytes = text.toByteArray(Charsets.UTF_8)
        val header = BluetoothTransferHeader(
            type = BluetoothContentType.Text,
            filename = "clipboard.txt",
            size = bytes.size.toLong()
        )
        sendTransfer(header, bytes) { progress -> emit(progress) }
    }.flowOn(Dispatchers.IO)

    /**
     * Send a file from a content URI over the RFCOMM connection.
     * Returns a Flow of progress (0.0 to 1.0).
     */
    fun sendFile(context: Context, uri: Uri): Flow<Double> = flow {
        val resolver = context.contentResolver
        val filename = ApiClient.getFileName(resolver, uri)
        val size = ApiClient.getFileSize(resolver, uri)
        if (size <= 0) throw BluetoothSessionException("Cannot determine file size")

        val header = BluetoothTransferHeader(
            type = BluetoothContentType.File,
            filename = filename,
            size = size
        )

        // Send header
        val out = outputStream ?: throw BluetoothSessionException("Not connected")
        out.write(BluetoothProtocol.buildTransferHeader(header))
        out.flush()

        // Stream file content in chunks
        var totalSent = 0L
        val buffer = ByteArray(BluetoothProtocol.SEND_CHUNK_SIZE)
        context.contentResolver.openInputStream(uri)?.use { input ->
            while (true) {
                currentCoroutineContext().ensureActive()
                val read = input.read(buffer)
                if (read == -1) break
                out.write(buffer, 0, read)
                out.flush()
                totalSent += read
                emit(totalSent.toDouble() / size)
            }
        } ?: throw BluetoothSessionException("Cannot open file URI")

        if (totalSent != size) {
            Log.w(TAG, "File size mismatch: expected=$size, sent=$totalSent")
        }
        emit(1.0)
    }.flowOn(Dispatchers.IO)

    /** Close the socket and release resources. */
    fun close() {
        isConnected = false
        isHandshakeComplete = false
        try {
            socket.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error closing socket", e)
        }
    }

    // --- Private helpers ---

    private suspend fun performHandshake(): Boolean = withContext(Dispatchers.IO) {
        val out = outputStream ?: return@withContext false
        val input = inputStream ?: return@withContext false

        // Send our handshake
        out.write(BluetoothProtocol.buildHandshake())
        out.flush()

        // Read peer's handshake (line until newline)
        val line = readLine(input) ?: return@withContext false
        val msg = BluetoothProtocol.parseHandshake(line)
        msg != null
    }

    private suspend fun receiveLoop() = withContext(Dispatchers.IO) {
        val input = inputStream ?: return@withContext

        while (isConnected) {
            currentCoroutineContext().ensureActive()

            // Read transfer header line
            val headerLine = readLine(input) ?: break // EOF or disconnect
            val header = BluetoothProtocol.parseTransferHeader(headerLine)
            if (header == null) {
                Log.w(TAG, "Invalid transfer header: $headerLine")
                continue
            }

            // Accumulate content bytes
            try {
                val data = readContent(input, header)
                val payload = BluetoothPayload(header, data)
                listener?.onTransferReceived(this@BluetoothSession, payload)
            } catch (e: Exception) {
                currentCoroutineContext().ensureActive()
                Log.e(TAG, "Error receiving content", e)
                listener?.onReceiveFailed(this@BluetoothSession, e)
                break
            }
        }
    }

    private suspend fun readContent(input: InputStream, header: BluetoothTransferHeader): ByteArray {
        val size = header.size
        val buffer = ByteArrayOutputStream(
            if (size <= 10 * 1024 * 1024) size.toInt() else 10 * 1024 * 1024
        )
        val chunk = ByteArray(BluetoothProtocol.SEND_CHUNK_SIZE)
        var remaining = size

        while (remaining > 0) {
            currentCoroutineContext().ensureActive()
            val toRead = minOf(remaining.toLong(), chunk.size.toLong()).toInt()
            val read = input.read(chunk, 0, toRead)
            if (read == -1) throw BluetoothSessionException("Unexpected EOF: expected $remaining more bytes")
            buffer.write(chunk, 0, read)
            remaining -= read

            val progress = (size - remaining).toDouble() / size
            listener?.onReceiveProgress(this@BluetoothSession, progress, header)
        }

        val data = buffer.toByteArray()
        if (data.size.toLong() != size) {
            throw BluetoothSessionException("Size mismatch: expected=$size, got=${data.size}")
        }
        return data
    }

    private suspend fun sendTransfer(
        header: BluetoothTransferHeader,
        content: ByteArray,
        emitProgress: suspend (Double) -> Unit
    ) {
        withContext(Dispatchers.IO) {
            val out = outputStream ?: throw BluetoothSessionException("Not connected")

            // Send header
            out.write(BluetoothProtocol.buildTransferHeader(header))
            out.flush()

            // Send content in chunks
            var offset = 0
            while (offset < content.size) {
                currentCoroutineContext().ensureActive()
                val len = minOf(BluetoothProtocol.SEND_CHUNK_SIZE, content.size - offset)
                out.write(content, offset, len)
                out.flush()
                offset += len
                emitProgress(offset.toDouble() / content.size)
            }
            emitProgress(1.0)
        }
    }

    /**
     * Read a single line (up to newline delimiter) from the input stream.
     * Returns null on EOF.
     */
    private fun readLine(input: InputStream): String? {
        val buffer = ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b == -1) return if (buffer.size() > 0) buffer.toString(Charsets.UTF_8.name()) else null
            if (b == BluetoothProtocol.DELIMITER.code) {
                return buffer.toString(Charsets.UTF_8.name())
            }
            buffer.write(b)
        }
    }

    companion object {
        private const val TAG = "BluetoothSession"
    }
}

class BluetoothSessionException(message: String) : Exception(message)
