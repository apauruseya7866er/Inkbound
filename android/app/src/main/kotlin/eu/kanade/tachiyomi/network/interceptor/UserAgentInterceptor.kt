package eu.kanade.tachiyomi.network.interceptor

import okhttp3.Interceptor
import okhttp3.Response

class UserAgentInterceptor(
    private val defaultUserAgentProvider: () -> String,
    /**
     * Per-host User-Agent pinned by the Cloudflare bypass proxy, or null when the
     * proxy has not solved that host.
     *
     * A `cf_clearance` is bound to the UA that earned it. Once the proxy's
     * browser earns one, our own requests have to present the UA it reported or
     * they are refused — so this overrides the app default for that host only.
     */
    private val pinnedUserAgentProvider: (String) -> String? = { null },
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val originalRequest = chain.request()

        if (!originalRequest.header("User-Agent").isNullOrEmpty()) {
            return chain.proceed(originalRequest)
        }

        val pinned = pinnedUserAgentProvider(originalRequest.url.host)
        val newRequest = originalRequest
            .newBuilder()
            .removeHeader("User-Agent")
            .addHeader("User-Agent", pinned ?: defaultUserAgentProvider())
            .build()
        return chain.proceed(newRequest)
    }
}