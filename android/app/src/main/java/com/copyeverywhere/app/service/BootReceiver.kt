package com.copyeverywhere.app.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Starts the foreground service on device boot so the user doesn't have to
 * manually open the app after a reboot.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            Log.d(TAG, "Boot completed — starting CopyEverywhereService")
            CopyEverywhereService.start(context)
        }
    }

    companion object {
        private const val TAG = "BootReceiver"
    }
}
