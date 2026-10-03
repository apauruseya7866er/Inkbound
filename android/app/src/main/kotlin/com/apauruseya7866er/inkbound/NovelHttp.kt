package com.apauruseya7866er.inkbound

import com.apauruseya7866er.inkbound.cloudstream.WebkitCookieJar
import com.lagradost.cloudstream3.CloudStreamApp
import eu.kanade.tachiyomi.network.AndroidCookieJar
import eu.kanade.tachiyomi.network.FlareSolverrConfig
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
import eu.kanade.tachiyomi.network.interceptor.CloudflareRequiredException
import eu.kanade.tachiyomi.network.interceptor.FlareSolverrClient
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Dedicated OkHttp fetch used ONLY for the LNReader novel-plugin path.
 * The reason this exists at all: a plain OkHttpClient on Android rides the
 * platform TLS stack (Conscrypt/BoringSSL), which produces a Chrome-like
 * JA3/TLS fingerprint — the same one the real LNReader app (React Native ->
 * OkHttp) presents. dart:io/Dio's fingerprint is what gets 403'd by
 * Cloudflare's bot-fight on sources like webnovel.com, no header block fixes
 * that. So do NOT install a custom SSLSocketFactory/TrustManager here — a
 * bespoke one would throw away the exact stack this file exists to use.
 */
object NovelHttp {
    /**
     * The device's real WebView User-Agent, set once from MainActivity.
     *
     * Dart sends a fixed desktop-Chrome string, and Cloudflare cross-checks the
     * UA against the TLS fingerprint and client hints — a Windows Chrome UA
     * arriving on an Android BoringSSL handshake is an obvious mismatch, and
     * novelupdates.com answers it with `cf-mitigated: challenge`. The real
     * LNReader app sends the device's own UA (its persisted getUserAgent), so
     * its UA and its TLS agree. NetworkHelper already does exactly this for the
     * Mihon lane, for the same reason.
     *
     * Null until set (tests, or before MainActivity runs) — the caller's own
     * header is used then, which is the behaviour that existed before.
     */
    @Volatile
    var deviceUserAgent: String? = null

    /**
     * Application context, set once from MainActivity.
     *
     * The Cloudflare interceptor needs a Context to build its solver WebView and
     * its main-thread executor. It deliberately does NOT read
     * [CloudStreamApp.getContext]: that is populated by the CloudStream
     * PluginHost, which a novel-only build never stands up — so asking it here
     * returned null on precisely the build whose only lane is this one, and the
     * interceptor was skipped silently.
     */
    @Volatile
    var appContext: android.content.Context? = null
    // Built on first use, not at app boot — stays dormant unless a novel
    // source actually needs it.
    private val client: OkHttpClient by lazy {
        val builder = OkHttpClient.Builder()
            .followRedirects(true)
            .followSslRedirects(true)
            // One jar, backed by the WebView CookieManager — the same one the
            // CloudStream (WebkitCookieJar) and Mihon (AndroidCookieJar) lanes
            // use. This lane previously kept its own in-memory store and MERGED
            // the WebView's cookies into it per request, deciding a shared name
            // by comparing a response timestamp against a WebView-visit stamp.
            // That merge is the likeliest reason a solve stopped working: the
            // two copies are already in one jar now, so there is nothing left
            // to arbitrate and no way for a stale copy to shadow a fresh one.
            .cookieJar(WebkitCookieJar())
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .callTimeout(30, TimeUnit.SECONDS)

        // Solve Cloudflare on this lane the way the Mihon lane does, instead of
        // only when the user notices an empty list and taps Solve. The
        // interceptor is where three things this lane needs are already right:
        //
        //  - It only fires on a real challenge: 403/503 from a server whose
        //    header names Cloudflare, so an ordinary site 403 is never mistaken.
        //  - createWebView() solves under the UA of the request that hit the
        //    challenge. Because [request] below rewrites User-Agent to
        //    [deviceUserAgent] BEFORE OkHttp runs, that is the same UA the
        //    replay sends — so the cf_clearance is not minted for a UA we never
        //    present. It also forwards the request's own headers, filtered by
        //    Chromium's IsRequestHeaderSafe.
        //  - It deletes any existing cf_clearance first and only counts a
        //    DIFFERENT one as success, so a stale cookie can't report a solve
        //    that never happened.
        //
        // Without a Context (unit tests, very early boot) this is skipped and
        // the lane behaves as it did before: plain fetch, Dart surfaces the
        // challenge and offers the visible solve.
        val context = appContext ?: CloudStreamApp.getContext()
        if (context != null) {
            FlareSolverrConfig.load(context)
            builder.addInterceptor(
                CloudflareInterceptor(
                    context,
                    AndroidCookieJar(),
                    { NetworkHelper.defaultUserAgentProvider() },
                    // Same proxy instance as the Mihon lane, so a session, a UA
                    // pin or a "the WebView can't clear this host" note learned
                    // on one lane applies to the other.
                    FlareSolverrClient.shared(),
                )
            )
        }
        builder.build()
    }

    /** What a novel fetch answers with. Response headers are carried because
     *  some plugins read a page count / content-type / token off them and
     *  throw without it. */
    data class Response(
        val status: Int,
        val body: String,
        val url: String,
        val headers: Map<String, String>,
        /** Cloudflare wants a human to pass a challenge. Dart surfaces this as
         *  the "Solve Cloudflare" prompt — without it a fresh install can never
         *  mint the cf_clearance that the shared WebView jar then carries, and
         *  the source stays blocked forever. */
        val cloudflare: Boolean,
    )

    /** `cf-mitigated: challenge` is Cloudflare saying so outright; 403/503 from
     *  a cloudflare server is the older signal. The cloudflare server header is
     *  required either way, so a plain 403 from the site is never mistaken. */
    private fun looksLikeChallenge(status: Int, headers: okhttp3.Headers): Boolean {
        val server = headers["server"]?.lowercase().orEmpty()
        if (!server.contains("cloudflare")) return false
        if (headers["cf-mitigated"]?.lowercase() == "challenge") return true
        return status == 403 || status == 503
    }


    /** Runs the call off the calling thread. */
    suspend fun request(
        url: String,
        method: String,
        headers: Map<String, String>,
        body: String?,
    ): Response = withContext(Dispatchers.IO) {
        val verb = method.uppercase()
        val reqBody = when {
            body != null -> body.toRequestBody(null)
            // POST/PUT/PATCH require a body per OkHttp; GET/HEAD/DELETE must not.
            verb == "POST" || verb == "PUT" || verb == "PATCH" -> "".toRequestBody(null)
            else -> null
        }
        val requestBuilder = Request.Builder().url(url).method(verb, reqBody)
        headers.forEach { (k, v) -> requestBuilder.header(k, v) }
        // Override the caller's UA with the device's own, so it matches the TLS
        // stack this client rides. A plugin that deliberately sets its own UA is
        // left alone — only the generic default is replaced.
        deviceUserAgent?.let { ua ->
            val sent = headers.entries
                .firstOrNull { it.key.equals("User-Agent", ignoreCase = true) }?.value
            if (sent == null || sent.contains("Windows NT")) {
                requestBuilder.header("User-Agent", ua)
            }
        }

        try {
            client.newCall(requestBuilder.build()).execute().use { response ->
                val respBody = response.body?.string() ?: ""
                // A header can legitimately repeat (Set-Cookie); join the way HTTP
                // itself does so nothing is silently dropped.
                val respHeaders = response.headers.names().associateWith { name ->
                    response.headers.values(name).joinToString(", ")
                }
                Response(
                    response.code,
                    respBody,
                    response.request.url.toString(),
                    respHeaders,
                    looksLikeChallenge(response.code, response.headers),
                )
            }
        } catch (e: CloudflareRequiredException) {
            // The interceptor's headless WebView could not clear an interactive
            // challenge. Reported as a 403 with cloudflare=true rather than a
            // thrown error so the plugin sees an ordinary refused fetch (it is
            // JavaScript and swallows its own failures anyway) and Dart latches
            // NovelCloudflare, which is what makes the visible
            // SourceWebViewActivity solve get offered.
            Response(403, "", e.url, emptyMap(), cloudflare = true)
        }
    }
}
