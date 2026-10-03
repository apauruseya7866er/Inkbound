package com.apauruseya7866er.inkbound

import android.webkit.CookieManager
import com.apauruseya7866er.inkbound.cloudstream.WebkitCookieJar
import okhttp3.Cookie
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The novel lane's cookie storage, driven through the real jar and the real
 * [CookieManager] rather than by calling helpers with hand-picked arguments.
 *
 * There is exactly one jar now: the WebView [CookieManager], shared with the
 * CloudStream and Mihon lanes. That is the point of these tests. The lane used
 * to keep a private in-memory store and merge the WebView's cookies into it on
 * every request, picking between two copies of the same name by comparing a
 * response timestamp against a WebView-visit stamp — so a clearance written by
 * the solver and one held by the client were two facts that could disagree, and
 * the loser was silently sent instead.
 *
 * Each test uses its own host: the CookieManager is process-wide, exactly as it
 * is in the app.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NovelCookieJarTest {

    private val jar = WebkitCookieJar()

    @Before
    fun acceptCookies() {
        CookieManager.getInstance().setAcceptCookie(true)
    }

    @Test
    fun `a cookie the client received is sent on the next request`() {
        val url = "https://received.test/".toHttpUrl()
        jar.saveFromResponse(url, listOf(cookie(url, "cf_clearance", "minted")))

        assertEquals("minted", valueOf(jar.loadForRequest(url), "cf_clearance"))
    }

    @Test
    fun `a clearance written by the solver is carried into the client`() {
        // The whole reason this lane reads the WebView jar: the user solves the
        // challenge in a visible WebView, and the novel client has to present
        // that same cookie on its next request.
        val url = "https://solved.test/".toHttpUrl()
        setWebViewCookie(url, "cf_clearance", "from-solver")

        assertEquals("from-solver", valueOf(jar.loadForRequest(url), "cf_clearance"))
    }

    @Test
    fun `a response overwrites the WebView copy instead of being arbitrated`() {
        // Previously a tiebreak decided between the two. Now the freshest write
        // to the one jar simply wins, so a stale copy cannot shadow it.
        val url = "https://overwrite.test/".toHttpUrl()
        setWebViewCookie(url, "cf_clearance", "stale")
        jar.saveFromResponse(url, listOf(cookie(url, "cf_clearance", "fresh")))

        val sent = jar.loadForRequest(url).filter { it.name == "cf_clearance" }
        assertEquals(1, sent.size)
        assertEquals("fresh", sent.single().value)
    }

    @Test
    fun `a name only one holder has is still sent`() {
        val url = "https://partial.test/".toHttpUrl()
        jar.saveFromResponse(url, listOf(cookie(url, "ours", "1")))
        setWebViewCookie(url, "theirs", "2")

        val sent = jar.loadForRequest(url)
        assertEquals("1", valueOf(sent, "ours"))
        assertEquals("2", valueOf(sent, "theirs"))
    }

    @Test
    fun `one host's cookies never reach another`() {
        // Cookies are domain-scoped in the WebView jar, so this is the jar's
        // guarantee rather than anything the client has to remember to check.
        val first = "https://scoped-one.test/".toHttpUrl()
        val second = "https://scoped-two.test/".toHttpUrl()
        jar.saveFromResponse(first, listOf(cookie(first, "cf_clearance", "one")))

        assertTrue(jar.loadForRequest(second).none { it.name == "cf_clearance" })
    }

    private fun cookie(url: okhttp3.HttpUrl, name: String, value: String) =
        Cookie.Builder().name(name).value(value).domain(url.host).build()

    private fun setWebViewCookie(url: okhttp3.HttpUrl, name: String, value: String) {
        CookieManager.getInstance().setCookie(url.toString(), "$name=$value")
    }

    private fun valueOf(cookies: List<Cookie>, name: String) =
        cookies.single { it.name == name }.value
}