package com.copyeverywhere.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
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
}
