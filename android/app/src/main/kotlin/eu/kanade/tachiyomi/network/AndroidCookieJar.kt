package eu.kanade.tachiyomi.network

import android.webkit.CookieManager
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

class AndroidCookieJar : CookieJar {

    val manager: CookieManager? = try {
        CookieManager.getInstance()
    } catch (e: Exception) {
        null
    }

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        val urlString = url.toString()

        cookies.forEach { manager?.setCookie(urlString, it.toString()) }
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        return get(url)
    }

    fun get(url: HttpUrl): List<Cookie> {
        val cookies = manager?.getCookie(url.toString())

        return if (!cookies.isNullOrEmpty()) {
            cookies.split(";").mapNotNull { Cookie.parse(url, it) }
        } else {
            emptyList()
        }
    }

    /**
     * Write a raw `Set-Cookie`-shaped string straight into the WebView jar.
     *
     * Used by the Cloudflare bypass proxy, which reports cookies as raw strings
     * rather than okhttp [Cookie]s. Passed through untouched: the proxy emits
     * `Domain=.example.com` with the leading dot on purpose, because Android's
     * CookieManager only treats a cookie as a domain cookie — covering the apex
     * and every subdomain — when that dot is present. Stripping it would make a
     * solve on `www.example.com` not cover `example.com`, so every tab switch
     * inside one source would re-solve.
     */
    fun saveCookieString(url: HttpUrl, cookieString: String) {
        manager?.setCookie(url.toString(), cookieString)
    }

    fun remove(url: HttpUrl, cookieNames: List<String>? = null, maxAge: Int = -1): Int {
        val urlString = url.toString()
        val cookies = manager?.getCookie(urlString) ?: return 0

        fun List<String>.filterNames(): List<String> {
            return if (cookieNames != null) {
                this.filter { it in cookieNames }
            } else {
                this
            }
        }

        return cookies.split(";")
            // trim so non-first cookies (" b=2") match the name filter
            .map { it.substringBefore("=").trim() }
            .filterNames()
            .onEach { manager?.setCookie(urlString, "$it=;Max-Age=$maxAge") }
            .count()
    }

    fun removeAll() {
        manager?.removeAllCookies {}
    }
}
