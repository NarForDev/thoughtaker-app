package com.narfordev.thoughtaker_app

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.BatteryManager
import android.provider.CalendarContract
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
        // Hands a prefilled draft to the user's own apps; nothing is created or sent without their tap.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "thoughtaker/intents").setMethodCallHandler { call, result ->
            val intent = when (call.method) {
                "insertEvent" -> Intent(Intent.ACTION_INSERT, CalendarContract.Events.CONTENT_URI)
                    .putExtra(CalendarContract.Events.TITLE, call.argument<String>("title"))
                    .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, call.argument<Number>("beginMs")?.toLong())
                    .putExtra(CalendarContract.EXTRA_EVENT_ALL_DAY, call.argument<Boolean>("allDay") ?: false)
                "composeEmail" -> Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:"))
                    .putExtra(Intent.EXTRA_SUBJECT, call.argument<String>("subject"))
                    .putExtra(Intent.EXTRA_TEXT, call.argument<String>("body"))
                "shareText" -> Intent.createChooser(
                    Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, call.argument<String>("text")),
                    null)
                else -> null
            }
            if (intent == null) return@setMethodCallHandler result.notImplemented()
            try {
                app.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success(true)
            } catch (e: ActivityNotFoundException) {
                result.success(false) // no calendar or mail app installed
            }
        }
    }

    companion object {
        const val ENGINE = "main"
        var configured = false
    }
}
