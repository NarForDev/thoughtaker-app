package com.narfordev.thoughtaker_app

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

// Not battery_plus: its Linux dbus dependency conflicts with universal_ble's.
class MainActivity : FlutterActivity() {
    // One engine for the process lifetime, so sync keeps running after the activity is swiped away.
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE)?.let { return it }
        // Dart starts later, from the activity, after configureFlutterEngine has registered plugins and channels.
        val engine = FlutterEngine(context.applicationContext)
        FlutterEngineCache.getInstance().put(ENGINE, engine)
        return engine
    }

    override fun shouldDestroyEngineWithHost() = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // A recreated activity gets the cached engine back; plugins and channels are already set up.
        if (configured) return
        configured = true
        super.configureFlutterEngine(flutterEngine)
        val app = applicationContext
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "thoughtaker/power").setMethodCallHandler { call, result ->
            when (call.method) {
                "isPluggedIn" -> {
                    // Sticky broadcast: reads the last battery state without keeping a receiver registered.
                    val battery = app.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                    result.success((battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0)
                }
                "keepAlive" -> {
                    val service = Intent(app, KeepAliveService::class.java)
                    if (call.arguments == true) app.startForegroundService(service) else app.stopService(service)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        const val ENGINE = "main"
        var configured = false
    }
}
