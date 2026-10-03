package eu.kanade.tachiyomi.network.interceptor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The proxy returns cookies whose domain may be blank, bare, or already dotted.
 * They are handed to Android's CookieManager, which only treats a cookie as a
 * domain cookie — matching the apex domain and every subdomain — when the
 * domain carries a leading dot. These pin that normalization, because losing it
 * costs a re-solve on every tab switch inside one source.
 */
class FlareSolverrCookieTest {

    private fun cookie(domain: String) =
        FlareSolverrCookie(name = "n", value = "v", domain = domain)

    @Test
    fun `a blank domain falls back to the request host with a leading dot`() {
        assertEquals(
            "n=v; Domain=.example.com; Path=/",
            cookie(domain = "").toRawCookieString("example.com"),
        )
    }

    @Test
    fun `an already-dotted domain is left as-is`() {
        assertEquals(
            "n=v; Domain=.foo.com; Path=/",
            cookie(domain = ".foo.com").toRawCookieString("example.com"),
        )
    }

    @Test
    fun `a bare domain gains a leading dot`() {
        assertEquals(
            "n=v; Domain=.foo.com; Path=/",
            cookie(domain = "foo.com").toRawCookieString("example.com"),
        )
    }
}

/**
 * A browser-based solver renders a JSON-API response inside its own JSON viewer
 * (`<html>…<pre>{json}</pre>…</html>`). A JSON source that receives that markup
 * fails to parse, so it has to be unwrapped — while a real HTML page, which may
 * legitimately contain a `<pre>`, must be left alone.
 */
class FlareSolverrJsonViewerTest {

    @Test
    fun `a JSON body inside the viewer is unwrapped`() {
        val html = "<html><head><title>x</title></head><body><pre>" +
            """{"status":200,"url":"https://a.test/"}""" +
            "</pre></body></html>"

        assertEquals("""{"status":200,"url":"https://a.test/"}""", unwrapBrowserJsonViewer(html))
    }

    @Test
    fun `a JSON array body inside the viewer is unwrapped`() {
        val html = "<html><body><pre>[1,2,3]</pre></body></html>"

        assertEquals("[1,2,3]", unwrapBrowserJsonViewer(html))
    }

    @Test
    fun `an unsolved challenge page is left as-is`() {
        val challenge = "<html lang=\"en-US\"><head><title>Just a moment...</title></head>" +
            "<body><div id=\"challenge-running\"></div></body></html>"

        assertNull(unwrapBrowserJsonViewer(challenge))
    }

    @Test
    fun `a plain HTML page containing a pre is left as-is`() {
        val page = "<html><body><pre>plain text, not json</pre></body></html>"

        assertNull(unwrapBrowserJsonViewer(page))
    }

    @Test
    fun `raw JSON is passed through untouched`() {
        assertNull(unwrapBrowserJsonViewer("""{"status":200}"""))
    }
}