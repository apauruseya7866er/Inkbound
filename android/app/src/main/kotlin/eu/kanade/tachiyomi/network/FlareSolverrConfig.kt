package eu.kanade.tachiyomi.network

import android.content.Context

/**
 * Where the optional Cloudflare bypass proxy lives, and whether it is on.
 *
 * Reikai reads these from its own preferences framework; this host has no
 * equivalent wired into the network package, so the values are kept here and
 * mirrored into Android [android.content.SharedPreferences] by the bridge so a
 * Dart settings toggle can set them.
 *
 * Deliberately two separate conditions, matching Reikai's UI: a non-blank URL
 * alone does nothing. That way turning the switch off disables the proxy without
 * losing the URL the user typed, and a half-finished URL is inert rather than
 * sending every challenged request to an unreachable host.
 */
object FlareSolverrConfig {
    private const val PREFS = "inkbound_cloudflare_bypass"
    private const val KEY_ENABLED = "enableProxy"
    private const val KEY_URL = "proxyUrl"

    /** True only when the user asked for the proxy AND gave it somewhere to go. */
    @Volatile
    var enabled: Boolean = false
        private set

    @Volatile
    var url: String = ""
        private set

    @Volatile
    private var loaded = false

    /** True when the proxy is on and reachable-looking. */
    val isActive: Boolean
        get() = enabled && url.isNotBlank()

    /** Read-through, idempotent. Safe to call before the Activity exists. */
    @Synchronized
    fun load(context: Context) {
        if (loaded) return
        val prefs = runCatching {
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        }.getOrNull()
        if (prefs == null) {
            // No context to read from: stay at defaults and retry next time
            // rather than caching "loaded" with nothing in it.
            return
        }
        enabled = prefs.getBoolean(KEY_ENABLED, false)
        url = prefs.getString(KEY_URL, "").orEmpty()
        loaded = true
    }

    fun set(context: Context, enable: Boolean, newUrl: String) {
        enabled = enable
        url = newUrl.trim()
        loaded = true
        runCatching {
            context.applicationContext
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_ENABLED, enable)
                .putString(KEY_URL, url)
                .apply()
        }
    }
}