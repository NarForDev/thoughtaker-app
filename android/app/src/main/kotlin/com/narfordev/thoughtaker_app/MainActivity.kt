package com.narfordev.thoughtaker_app

import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Not battery_plus: its Linux dbus dependency conflicts with universal_ble's.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "thoughtaker/power").setMethodCallHandler { call, result ->
            if (call.method == "isPluggedIn") {
                // Sticky broadcast: reads the last battery state without keeping a receiver registered.
                val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                result.success((battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0)
            } else {
                result.notImplemented()
            }
        }
    }
}
