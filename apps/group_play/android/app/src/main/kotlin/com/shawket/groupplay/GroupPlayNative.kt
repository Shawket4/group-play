package com.shawket.groupplay

import android.content.Context
import android.util.Log

/** Gives the Rust engine the JavaVM + application context (iroh's DNS, cpal) before Dart runs. */
object GroupPlayNative {
    @JvmStatic
    private external fun install(context: Context)

    fun installOnce(context: Context) {
        try {
            System.loadLibrary("group_play_frb")
            install(context.applicationContext)
        } catch (e: Throwable) {
            Log.w("GroupPlay", "native install failed: ${e.message}")
        }
    }
}
