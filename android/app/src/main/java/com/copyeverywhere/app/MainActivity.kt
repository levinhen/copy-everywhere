package com.copyeverywhere.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.copyeverywhere.app.service.CopyEverywhereService
import com.copyeverywhere.app.ui.config.ConfigScreen
import com.copyeverywhere.app.ui.main.MainScreen
import com.copyeverywhere.app.ui.theme.CopyEverywhereTheme

class MainActivity : ComponentActivity() {

    private val notificationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        // Start service regardless — it just won't show transfer notifications without the permission
        CopyEverywhereService.start(this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        requestNotificationPermissionAndStartService()
        requestBatteryOptimizationExemption()
        setContent {
            CopyEverywhereTheme {
                val navController = rememberNavController()
                NavHost(navController = navController, startDestination = "main") {
                    composable("main") {
                        MainScreen(
                            onNavigateToConfig = { navController.navigate("config") }
                        )
                    }
                    composable("config") {
                        ConfigScreen(onNavigateBack = { navController.popBackStack() })
                    }
                }
            }
        }
    }

    private fun requestNotificationPermissionAndStartService() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                return
            }
        }
        CopyEverywhereService.start(this)
    }

    /**
     * Request exemption from battery optimization so the foreground service
     * and SSE connection are not killed by Doze mode. Shows the system dialog
     * only if the app is not already exempted.
     */
    @Suppress("BatteryLife") // Justified — the app needs a persistent SSE/Bluetooth connection
    private fun requestBatteryOptimizationExemption() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (!pm.isIgnoringBatteryOptimizations(packageName)) {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(intent)
        }
    }
}
