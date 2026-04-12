package com.copyeverywhere.app.data

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Manages Bluetooth RFCOMM server (listening) and client (connecting) roles.
 * Mirrors the macOS BluetoothService — owns the active BluetoothSession and
 * delegates events up to a Listener.
 */
class BluetoothService(private val context: Context) : BluetoothSession.Listener {

    interface Listener {
        fun onSessionReady(session: BluetoothSession)
        fun onSessionHandshakeFailed(session: BluetoothSession, error: Exception)
        fun onTransferReceived(session: BluetoothSession, payload: BluetoothPayload)
        fun onReceiveProgress(session: BluetoothSession, progress: Double, header: BluetoothTransferHeader)
        fun onReceiveFailed(session: BluetoothSession, error: Exception)
        fun onSessionDisconnected(session: BluetoothSession)
    }

    var listener: Listener? = null

    var activeSession: BluetoothSession? = null
        private set

    val isSessionReady: Boolean
        get() = activeSession?.isHandshakeComplete == true

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var serverJob: Job? = null
    private var serverSocket: BluetoothServerSocket? = null

    private val bluetoothAdapter: BluetoothAdapter?
        get() {
            val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            return manager?.adapter
        }

    /**
     * Start the RFCOMM server — listens for incoming connections in a loop.
     * Each accepted connection creates a BluetoothSession that auto-starts handshake.
     */
    @SuppressLint("MissingPermission")
    fun startServer() {
        if (serverJob != null) {
            Log.d(TAG, "RFCOMM server already running")
            return
        }

        val adapter = bluetoothAdapter
        if (adapter == null) {
            Log.w(TAG, "Bluetooth adapter not available")
            return
        }

        if (!adapter.isEnabled) {
            Log.w(TAG, "Bluetooth is not enabled")
            return
        }

        serverJob = scope.launch(Dispatchers.IO) {
            try {
                val ss = adapter.listenUsingRfcommWithServiceRecord(
                    BluetoothProtocol.SERVICE_NAME,
                    BluetoothProtocol.SERVICE_UUID
                )
                serverSocket = ss
                Log.d(TAG, "RFCOMM server started, waiting for connections...")

                while (true) {
                    val clientSocket: BluetoothSocket = ss.accept() // blocks
                    Log.d(TAG, "Accepted connection from ${clientSocket.remoteDevice?.address}")
                    createSession(clientSocket, clientSocket.remoteDevice)
                }
            } catch (e: Exception) {
                // Server socket closed or error
                Log.d(TAG, "RFCOMM server stopped: ${e.message}")
            }
        }
    }

    /** Stop the RFCOMM server. */
    fun stopServer() {
        serverJob?.cancel()
        serverJob = null
        try {
            serverSocket?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error closing server socket", e)
        }
        serverSocket = null
        Log.d(TAG, "RFCOMM server stopped")
    }

    /**
     * Connect to a remote device as a client.
     * Creates an RFCOMM socket, connects, and starts a session.
     */
    @SuppressLint("MissingPermission")
    fun connect(device: BluetoothDevice) {
        scope.launch(Dispatchers.IO) {
            try {
                val socket = device.createRfcommSocketToServiceRecord(BluetoothProtocol.SERVICE_UUID)
                // Cancel discovery to speed up connection
                bluetoothAdapter?.cancelDiscovery()
                socket.connect()
                Log.d(TAG, "Connected to ${device.address}")
                createSession(socket, device)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to connect to ${device.address}", e)
                // Report as handshake failure with a dummy session
                val dummySocket = try {
                    device.createRfcommSocketToServiceRecord(BluetoothProtocol.SERVICE_UUID)
                } catch (_: Exception) { null }
                if (dummySocket != null) {
                    val session = BluetoothSession(dummySocket, device)
                    listener?.onSessionHandshakeFailed(session, e)
                }
            }
        }
    }

    /**
     * Connect to a remote device by Bluetooth address.
     */
    @SuppressLint("MissingPermission")
    fun connectByAddress(address: String) {
        val adapter = bluetoothAdapter ?: return
        val device = adapter.getRemoteDevice(address) ?: return
        connect(device)
    }

    /** Disconnect the active session. */
    fun disconnectSession() {
        activeSession?.close()
        activeSession = null
    }

    /** Release all resources. */
    fun destroy() {
        disconnectSession()
        stopServer()
        scope.cancel()
    }

    // --- Private helpers ---

    private fun createSession(socket: BluetoothSocket, device: BluetoothDevice?) {
        // Close any existing session
        activeSession?.close()

        val session = BluetoothSession(socket, device)
        session.listener = this
        activeSession = session

        // Start handshake + receive loop in a coroutine
        scope.launch {
            session.start()
        }
    }

    // --- BluetoothSession.Listener ---

    override fun onHandshakeComplete(session: BluetoothSession) {
        Log.d(TAG, "Handshake complete with ${session.deviceName}")
        listener?.onSessionReady(session)
    }

    override fun onHandshakeFailed(session: BluetoothSession, error: Exception) {
        Log.e(TAG, "Handshake failed with ${session.deviceName}", error)
        if (activeSession == session) {
            activeSession = null
        }
        listener?.onSessionHandshakeFailed(session, error)
    }

    override fun onTransferReceived(session: BluetoothSession, payload: BluetoothPayload) {
        Log.d(TAG, "Transfer received: type=${payload.header.type}, size=${payload.data.size}")
        listener?.onTransferReceived(session, payload)
    }

    override fun onReceiveProgress(session: BluetoothSession, progress: Double, header: BluetoothTransferHeader) {
        listener?.onReceiveProgress(session, progress, header)
    }

    override fun onReceiveFailed(session: BluetoothSession, error: Exception) {
        Log.e(TAG, "Receive failed from ${session.deviceName}", error)
        listener?.onReceiveFailed(session, error)
    }

    override fun onDisconnected(session: BluetoothSession) {
        Log.d(TAG, "Disconnected from ${session.deviceName}")
        if (activeSession == session) {
            activeSession = null
        }
        listener?.onSessionDisconnected(session)
    }

    companion object {
        private const val TAG = "BluetoothService"
    }
}
