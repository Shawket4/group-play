package com.shawket.tutti

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var channel: TuttiChannel? = null
    private var nextCode = 1000
    private val permissionCallbacks = mutableMapOf<Int, () -> Unit>()
    private val resultCallbacks = mutableMapOf<Int, (Int, Intent?) -> Unit>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = TuttiChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.dispose()
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    fun askPermissions(perms: Array<String>, done: () -> Unit) {
        val code = nextCode++
        permissionCallbacks[code] = done
        requestPermissions(perms, code)
    }

    fun askActivityResult(intent: Intent, done: (Int, Intent?) -> Unit) {
        val code = nextCode++
        resultCallbacks[code] = done
        @Suppress("DEPRECATION")
        startActivityForResult(intent, code)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        permissionCallbacks.remove(requestCode)?.invoke()
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        resultCallbacks.remove(requestCode)?.invoke(resultCode, data)
    }
}
