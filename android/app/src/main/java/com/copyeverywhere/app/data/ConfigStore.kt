package com.copyeverywhere.app.data

import android.content.Context
import android.content.SharedPreferences
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

data class PairedBluetoothDevice(
    val name: String,
    val address: String
)

enum class TransferMode {
    LanServer,
    Bluetooth
}

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "config")

class ConfigStore(private val context: Context) {

    private object Keys {
        val HOST_URL = stringPreferencesKey("host_url")
        val DEVICE_NAME = stringPreferencesKey("device_name")
        val DEVICE_ID = stringPreferencesKey("device_id")
        val TARGET_DEVICE_ID = stringPreferencesKey("target_device_id")
        val TRANSFER_MODE = stringPreferencesKey("transfer_mode")
        val PAIRED_BLUETOOTH_DEVICES = stringPreferencesKey("paired_bluetooth_devices")
        val LAST_CONNECTED_BT_ADDRESS = stringPreferencesKey("last_connected_bt_address")
    }

    private val gson = Gson()

    private val encryptedPrefs: SharedPreferences by lazy {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            "secure_config",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    val hostUrl: Flow<String> = context.dataStore.data.map { it[Keys.HOST_URL] ?: "" }
    val deviceName: Flow<String> = context.dataStore.data.map { it[Keys.DEVICE_NAME] ?: android.os.Build.MODEL }
    val deviceId: Flow<String> = context.dataStore.data.map { it[Keys.DEVICE_ID] ?: "" }
    val targetDeviceId: Flow<String> = context.dataStore.data.map { it[Keys.TARGET_DEVICE_ID] ?: "" }
    val transferMode: Flow<TransferMode> = context.dataStore.data.map {
        when (it[Keys.TRANSFER_MODE]) {
            "Bluetooth" -> TransferMode.Bluetooth
            else -> TransferMode.LanServer
        }
    }

    suspend fun setHostUrl(url: String) {
        context.dataStore.edit { it[Keys.HOST_URL] = url }
    }

    suspend fun setDeviceName(name: String) {
        context.dataStore.edit { it[Keys.DEVICE_NAME] = name }
    }

    suspend fun setDeviceId(id: String) {
        context.dataStore.edit { it[Keys.DEVICE_ID] = id }
    }

    suspend fun setTargetDeviceId(id: String) {
        context.dataStore.edit { it[Keys.TARGET_DEVICE_ID] = id }
    }

    suspend fun setTransferMode(mode: TransferMode) {
        context.dataStore.edit { it[Keys.TRANSFER_MODE] = mode.name }
    }

    val pairedBluetoothDevices: Flow<List<PairedBluetoothDevice>> = context.dataStore.data.map {
        val json = it[Keys.PAIRED_BLUETOOTH_DEVICES] ?: "[]"
        try {
            val type = object : TypeToken<List<PairedBluetoothDevice>>() {}.type
            gson.fromJson<List<PairedBluetoothDevice>>(json, type) ?: emptyList()
        } catch (_: Exception) {
            emptyList()
        }
    }

    val lastConnectedBtAddress: Flow<String> = context.dataStore.data.map {
        it[Keys.LAST_CONNECTED_BT_ADDRESS] ?: ""
    }

    suspend fun addPairedDevice(device: PairedBluetoothDevice) {
        context.dataStore.edit { prefs ->
            val json = prefs[Keys.PAIRED_BLUETOOTH_DEVICES] ?: "[]"
            val type = object : TypeToken<MutableList<PairedBluetoothDevice>>() {}.type
            val list: MutableList<PairedBluetoothDevice> = try {
                gson.fromJson(json, type) ?: mutableListOf()
            } catch (_: Exception) {
                mutableListOf()
            }
            // Replace existing by address or add new
            list.removeAll { it.address == device.address }
            list.add(device)
            prefs[Keys.PAIRED_BLUETOOTH_DEVICES] = gson.toJson(list)
        }
    }

    suspend fun removePairedDevice(address: String) {
        context.dataStore.edit { prefs ->
            val json = prefs[Keys.PAIRED_BLUETOOTH_DEVICES] ?: "[]"
            val type = object : TypeToken<MutableList<PairedBluetoothDevice>>() {}.type
            val list: MutableList<PairedBluetoothDevice> = try {
                gson.fromJson(json, type) ?: mutableListOf()
            } catch (_: Exception) {
                mutableListOf()
            }
            list.removeAll { it.address == address }
            prefs[Keys.PAIRED_BLUETOOTH_DEVICES] = gson.toJson(list)
        }
    }

    suspend fun setLastConnectedBtAddress(address: String) {
        context.dataStore.edit { it[Keys.LAST_CONNECTED_BT_ADDRESS] = address }
    }

    fun getAccessToken(): String {
        return encryptedPrefs.getString("access_token", "") ?: ""
    }

    fun setAccessToken(token: String) {
        encryptedPrefs.edit().putString("access_token", token).apply()
    }
}
