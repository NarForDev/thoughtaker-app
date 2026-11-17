package com.narfordev.thoughtaker_app

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract.Calendars
import android.provider.CalendarContract.Events
import android.provider.CalendarContract.Reminders
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

// Writes dated items straight into the user's own calendar, so they sync to their account and show on every device.
object CalendarChannel {
    private const val REQUEST = 7
    private val perms = arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR)
    private var pending: MethodChannel.Result? = null

    fun register(messenger: BinaryMessenger, app: Context) {
        MethodChannel(messenger, "thoughtaker/calendar").setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAccess" -> result.success(granted(app))
                "requestAccess" -> {
                    val activity = MainActivity.current
                    if (granted(app) || activity == null) {
                        result.success(granted(app))
                    } else {
                        pending?.success(false)
                        pending = result
                        activity.requestPermissions(perms, REQUEST)
                    }
                }
                "insert" -> result.success(if (granted(app)) insert(app, call) else null)
                "delete" -> {
                    val id = call.argument<Number>("eventId")!!.toLong()
                    if (granted(app)) app.contentResolver.delete(ContentUris.withAppendedId(Events.CONTENT_URI, id), null, null)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun onPermissionResult(requestCode: Int, grants: IntArray) {
        if (requestCode != REQUEST) return
        pending?.success(grants.isNotEmpty() && grants.all { it == PackageManager.PERMISSION_GRANTED })
        pending = null
    }

    private fun granted(c: Context) = perms.all { c.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    // The primary calendar if there is one, else any visible calendar the user can write to.
    private fun calendarId(c: Context): Long? = c.contentResolver.query(
        Calendars.CONTENT_URI,
        arrayOf(Calendars._ID),
        "${Calendars.VISIBLE} = 1 AND ${Calendars.CALENDAR_ACCESS_LEVEL} >= ${Calendars.CAL_ACCESS_CONTRIBUTOR}",
        null,
        "${Calendars.IS_PRIMARY} DESC",
    )?.use { if (it.moveToFirst()) it.getLong(0) else null }

    private fun insert(c: Context, call: MethodCall): Long? {
        val calendar = calendarId(c) ?: return null
        val begin = call.argument<Number>("beginMs")!!.toLong()
        val allDay = call.argument<Boolean>("allDay") ?: false
        val event = ContentValues().apply {
            put(Events.CALENDAR_ID, calendar)
            put(Events.TITLE, call.argument<String>("title"))
            put(Events.DESCRIPTION, call.argument<String>("description"))
            put(Events.DTSTART, begin)
            put(Events.DTEND, begin + if (allDay) 86_400_000L else 3_600_000L)
            put(Events.ALL_DAY, if (allDay) 1 else 0)
            put(Events.EVENT_TIMEZONE, if (allDay) "UTC" else TimeZone.getDefault().id) // all-day events are UTC midnights
        }
        val id = c.contentResolver.insert(Events.CONTENT_URI, event)?.lastPathSegment?.toLongOrNull() ?: return null
        call.argument<Int>("alertMinutes")?.let { minutes ->
            c.contentResolver.insert(Reminders.CONTENT_URI, ContentValues().apply {
                put(Reminders.EVENT_ID, id)
                put(Reminders.MINUTES, minutes)
                put(Reminders.METHOD, Reminders.METHOD_ALERT)
            })
        }
        return id
    }
}
