package eu.kanade.tachiyomi.network.interceptor

import eu.kanade.tachiyomi.network.AndroidCookieJar
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.Headers
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.jsoup.Jsoup
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * Resolves Cloudflare challenges through a self-hosted bypass proxy that speaks
 * the FlareSolverr API — Solverr (recommended), Byparr or FlareSolverr, all on
 * port 8191.
 *
 * This exists because there is a tier of Cloudflare protection the in-app
 * WebView cannot beat and cookie replay cannot fix. A clearance is bound to the
 * TLS / `__cf_bm` fingerprint of whatever solved it, and OkHttp cannot reproduce
 * headless Chrome's, so handing a solved `cf_clearance` back to the app's own
 * HTTP client is refused. The way out is to serve the proxy's RESPONSE rather
 * than replaying its cookies — which is what [resolve] returns, and why this
 * class builds an okhttp [Response] instead of installing cookies and retrying.
 *
 * Kept separate from [CloudflareInterceptor] so all the proxy internals live in
 * one place and the interceptor keeps only detection and the decision to
 * delegate.
 *
 * Ported from Reikai's FlareSolverrClient.
 */
class FlareSolverrClient(
    private val cookieManager: AndroidCookieJar,
) {

    private val flareSolverrClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .callTimeout(90, TimeUnit.SECONDS)
            .build()
    }

    private val json = Json { ignoreUnknownKeys = true }

    // One active solve per hostname; concurrent 403s for the same host coalesce
    // instead of each spawning their own browser session.
    private val pendingFSSolves = ConcurrentHashMap<String, CompletableFuture<Unit>>()

    // Per-host User-Agent pin set when the proxy solves. Follow-up requests to
    // that host must present it or the clearance stops validating.
    private val fsPinByHost = ConcurrentHashMap<String, String>()

    // Hosts where the WebView failed and the proxy succeeded. Lets later
    // requests skip the wasted WebView attempt entirely.
    private val fsRequiredHosts: MutableSet<String> = ConcurrentHashMap.newKeySet()

    // Single shared proxy session, created on first use and reused so the proxy's
    // browser keeps its cleared cookies in memory and follow-ups skip the
    // challenge.
    private val fsSessionLock = Any()

    @Volatile
    private var fsSessionId: String? = null

    // Byparr (Camoufox) is sessionless: it has no sessions.create and 500s on it.
    // Once seen, stop trying and send sessionless requests for this app session.
    @Volatile
    private var fsSessionsSupported = true

    fun pinnedUserAgentFor(host: String): String? = fsPinByHost[host]

    fun shouldSkipWebView(host: String): Boolean = fsRequiredHosts.contains(host)

    /**
     * Mark a host as WebView-unsolvable so later requests go straight to the
     * proxy.
     *
     * Without this the WebView's solve timeout is re-paid on every request to a
     * host it cannot clear — listing, details, chapters, images — which
     * serialises long blocks and makes that source look hung. The set is
     * otherwise only populated on a proxy success, which never happens for a
     * host the proxy also cannot clear.
     */
    fun markWebViewUnsolvable(host: String) {
        fsRequiredHosts.add(host)
    }

    /**
     * Solve for [request] and return the proxy's fully-fetched response, or null
     * when a sibling thread is already solving for the same host (the caller
     * then falls through to a normal retry with whatever the jar holds).
     */
    fun resolve(flareSolverrUrl: String, request: Request): Response? =
        resolveWithDedup(flareSolverrUrl, request)

    /**
     * Connectivity check for the settings "Test" button: a sessionless solve of
     * google.com, returning the User-Agent the proxy reports on success so the
     * caller can pin it as the app default. Runs off the calling thread.
     */
    suspend fun test(flareSolverrUrl: String): Result<String> = withContext(Dispatchers.IO) {
        runCatching {
            val command = buildJsonObject {
                put("cmd", "request.get")
                put("url", "https://www.google.com/")
                put("maxTimeout", 60000)
            }
            val body = json.encodeToString(JsonObject.serializer(), command)
                .toRequestBody(JSON_MEDIA_TYPE)
            val req = Request.Builder()
                .url("${flareSolverrUrl.trimEnd('/')}/v1")
                .post(body)
                .build()
            val text = flareSolverrClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) throw IOException("FlareSolverr returned HTTP ${resp.code}")
                resp.body.string()
            }
            val result = json.decodeFromString(FlareSolverrResponse.serializer(), text)
            if (result.status != "ok") {
                throw IOException(result.message.ifBlank { "FlareSolverr error" })
            }
            val solution = result.solution
                ?: throw IOException("FlareSolverr returned no solution")
            if (solution.status !in 200..299) {
                throw IOException("FlareSolverr solution status: ${solution.status}")
            }
            solution.userAgent
        }
    }

    private fun resolveWithDedup(flareSolverrUrl: String, request: Request): Response? {
        val host = request.url.host

        while (true) {
            val existing = pendingFSSolves[host]
            if (existing != null) {
                // Someone else is solving this host. Wait, then return null so the
                // caller proceeds normally with whatever the jar holds by now.
                existing.get(90, TimeUnit.SECONDS)
                return null
            }
            val future = CompletableFuture<Unit>()
            if (pendingFSSolves.putIfAbsent(host, future) == null) {
                try {
                    cookieManager.remove(request.url, COOKIE_NAMES, 0)
                    val response = resolveWithProxy(flareSolverrUrl, request)
                    future.complete(Unit)
                    return response
                } catch (e: Exception) {
                    future.completeExceptionally(e)
                    throw e
                } finally {
                    pendingFSSolves.remove(host)
                }
            }
            // Lost the race between the check and putIfAbsent: loop and wait.
        }
    }

    private fun resolveWithProxy(flareSolverrUrl: String, request: Request): Response {
        val sessionId = ensureSession(flareSolverrUrl)
        return runProxyRequest(flareSolverrUrl, request, sessionId, allowRetry = sessionId != null)
    }

    /**
     * The shared session id, or null when the server is sessionless (Byparr) or
     * creating one failed. Null means "send requests without a session": the
     * solve still proceeds, just without the warm-cookie reuse.
     */
    private fun ensureSession(flareSolverrUrl: String): String? {
        if (!fsSessionsSupported) return null
        fsSessionId?.let { return it }
        return synchronized(fsSessionLock) {
            if (!fsSessionsSupported) return@synchronized null
            fsSessionId?.let { return@synchronized it }
            // Only real FlareSolverr implements sessions; Byparr 500s on
            // sessions.create (it has no url to navigate) and spams its log with a
            // stack trace. Probe the root banner first.
            if (!supportsSessions(flareSolverrUrl)) {
                fsSessionsSupported = false
                return@synchronized null
            }
            val newId = "inkbound-${UUID.randomUUID()}"
            val body = """{"cmd":"sessions.create","session":"$newId"}"""
                .toRequestBody(JSON_MEDIA_TYPE)
            val req = Request.Builder()
                .url("${flareSolverrUrl.trimEnd('/')}/v1")
                .post(body)
                .build()
            val created = runCatching {
                flareSolverrClient.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) return@runCatching false
                    json.decodeFromString(FlareSolverrResponse.serializer(), resp.body.string())
                        .status == "ok"
                }
            }.getOrDefault(false)
            if (!created) {
                // Sessionless solver, or a transient error. request.get still
                // works without a session, so do that rather than fail.
                fsSessionsSupported = false
                return@synchronized null
            }
            fsSessionId = newId
            newId
        }
    }

    /**
     * True only for real FlareSolverr, whose root endpoint returns a JSON banner
     * naming it. Failures default to false, i.e. go sessionless.
     */
    private fun supportsSessions(flareSolverrUrl: String): Boolean = runCatching {
        val req = Request.Builder().url("${flareSolverrUrl.trimEnd('/')}/").get().build()
        flareSolverrClient.newCall(req).execute().use { resp ->
            resp.isSuccessful && resp.body.string().contains("FlareSolverr", ignoreCase = true)
        }
    }.getOrDefault(false)

    private fun runProxyRequest(
        flareSolverrUrl: String,
        request: Request,
        sessionId: String?,
        allowRetry: Boolean,
    ): Response {
        val targetUrl = request.url.toString()

        // Full-response mode (returnOnlyCookies defaults to false): the proxy
        // returns the body its headless browser fetched, so it can be served
        // directly instead of replaying cf_clearance through OkHttp — the path
        // Cloudflare's TLS / __cf_bm fingerprinting often rejects.
        //
        // A Cloudflare-gated POST must be replayed as a POST with the original
        // body, or the proxy would GET the URL and return the wrong page. Build
        // the command through the JSON DSL so the body cannot break the envelope.
        val isPost = request.method.equals("POST", ignoreCase = true)
        val postData = request.body
            ?.takeIf { isPost }
            ?.let { rb -> Buffer().also { rb.writeTo(it) }.readUtf8() }
        val command = buildJsonObject {
            put("cmd", if (isPost) "request.post" else "request.get")
            put("url", targetUrl)
            if (isPost) put("postData", postData ?: "")
            if (sessionId != null) put("session", sessionId)
            put("maxTimeout", 60000)
        }
        val body = json.encodeToString(JsonObject.serializer(), command)
            .toRequestBody(JSON_MEDIA_TYPE)

        val fsRequest = Request.Builder()
            .url("${flareSolverrUrl.trimEnd('/')}/v1")
            .post(body)
            .build()

        val fsResponse = flareSolverrClient.newCall(fsRequest).execute()
        val fsBody = fsResponse.body.string()

        if (!fsResponse.isSuccessful) {
            throw IOException("FlareSolverr returned HTTP ${fsResponse.code}")
        }

        val result = json.decodeFromString(FlareSolverrResponse.serializer(), fsBody)

        // A proxy restart or session GC invalidates the cached id. Detect that
        // from the message and recreate once.
        if (result.status != "ok" && allowRetry && sessionId != null &&
            result.message.contains("session", ignoreCase = true)
        ) {
            synchronized(fsSessionLock) {
                if (fsSessionId == sessionId) fsSessionId = null
            }
            val freshId = ensureSession(flareSolverrUrl)
            return runProxyRequest(flareSolverrUrl, request, freshId, allowRetry = false)
        }

        if (result.status != "ok") {
            throw IOException("FlareSolverr error: ${result.message}")
        }

        val solution = result.solution
            ?: throw IOException("FlareSolverr returned no solution: ${result.message}")

        if (solution.status !in 200..299) {
            throw IOException("FlareSolverr solution status: ${solution.status}")
        }

        // Best-effort: stash cookies + UA so unrelated future requests to this
        // host can succeed without re-invoking the proxy. THIS request is served
        // by the synthetic response built below, not by these.
        solution.cookies.forEach { fsCookie ->
            runCatching {
                cookieManager.saveCookieString(
                    request.url,
                    fsCookie.toRawCookieString(request.url.host),
                )
            }
        }
        if (solution.userAgent.isNotBlank()) {
            fsPinByHost[request.url.host] = solution.userAgent
        }
        fsRequiredHosts.add(request.url.host)

        return buildResponse(request, solution)
    }

    private fun buildResponse(request: Request, solution: FlareSolverrSolution): Response {
        val reportedContentType = solution.headers
            .entries.firstOrNull { it.key.equals("content-type", ignoreCase = true) }
            ?.value
            ?: "text/html; charset=UTF-8"

        // A browser-based solver renders a JSON-API response inside its built-in
        // JSON/plaintext viewer (<html>…<pre>{json}</pre>…), so a JSON source
        // would receive HTML and fail to parse. Unwrap it back to raw JSON; HTML
        // page sources are untouched.
        val unwrappedJson = unwrapBrowserJsonViewer(solution.response)
        val responseText = unwrappedJson ?: solution.response
        val contentType = if (unwrappedJson != null) JSON_CONTENT_TYPE else reportedContentType

        val body = responseText.toResponseBody(contentType.toMediaTypeOrNull())

        val headersBuilder = Headers.Builder()
        solution.headers.forEach { (name, value) ->
            // The body is already decoded, so passing Content-Encoding /
            // Content-Length / Transfer-Encoding through would make OkHttp try
            // to re-decode and break. Set-Cookie was applied to the jar above.
            // Content-Type is set from [contentType] so it stays consistent with
            // any JSON unwrap.
            if (name.equals("content-encoding", ignoreCase = true)) return@forEach
            if (name.equals("content-length", ignoreCase = true)) return@forEach
            if (name.equals("transfer-encoding", ignoreCase = true)) return@forEach
            if (name.equals("set-cookie", ignoreCase = true)) return@forEach
            if (name.equals("content-type", ignoreCase = true)) return@forEach
            runCatching { headersBuilder.add(name, value) }
        }
        headersBuilder.add("Content-Type", contentType)

        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(solution.status)
            .message(if (solution.status in 200..299) "OK" else "FlareSolverr")
            .headers(headersBuilder.build())
            .body(body)
            .build()
    }

    companion object {
        @Volatile
        private var shared: FlareSolverrClient? = null

        /**
         * One instance for the whole process.
         *
         * The proxy session, the per-host User-Agent pins and the set of hosts
         * the WebView cannot clear are per-app state, not per-lane: two instances
         * would open two proxy sessions for one host and each would re-solve what
         * the other had already cleared. AndroidCookieJar itself is stateless (it
         * reads and writes the shared WebView jar), so any instance works.
         */
        fun shared(): FlareSolverrClient = synchronized(this) {
            shared ?: FlareSolverrClient(AndroidCookieJar()).also { shared = it }
        }
    }
}

private val JSON_MEDIA_TYPE = "application/json".toMediaType()
private const val JSON_CONTENT_TYPE = "application/json; charset=UTF-8"
private val COOKIE_NAMES = listOf("cf_clearance")

/**
 * A browser-based solver renders a JSON-API response inside its browser's JSON /
 * plaintext viewer: `<html>…<body><pre>{json}</pre>…</body></html>` (Firefox /
 * Camoufox, used by Byparr) or the same shape with a json-formatter div (Chrome,
 * used by FlareSolverr). A JSON source or light-novel plugin would then receive
 * HTML and fail to parse.
 *
 * Returns the raw JSON if [response] is such a wrapper, else null (serve as-is).
 * Detection is browser-agnostic: markup whose first `<pre>` — entity-decoded via
 * Jsoup's [org.jsoup.nodes.Element.wholeText], so `&lt;` inside string values is
 * restored — is itself JSON.
 */
internal fun unwrapBrowserJsonViewer(response: String): String? {
    if (!response.trimStart().startsWith('<')) return null
    if (!response.contains("<pre", ignoreCase = true)) return null
    val pre = Jsoup.parse(response).selectFirst("pre")?.wholeText()?.trim().orEmpty()
    return pre.takeIf { it.startsWith('{') || it.startsWith('[') }
}

@Serializable
private data class FlareSolverrResponse(
    val status: String,
    val message: String = "",
    // Nullable because sessions.create responses carry no solution field.
    val solution: FlareSolverrSolution? = null,
)

@Serializable
private data class FlareSolverrSolution(
    val url: String = "",
    val status: Int = 0,
    val headers: Map<String, String> = emptyMap(),
    val response: String = "",
    val cookies: List<FlareSolverrCookie> = emptyList(),
    @SerialName("userAgent") val userAgent: String = "",
)

@Serializable
internal data class FlareSolverrCookie(
    val name: String,
    val value: String,
    val domain: String = "",
    val path: String = "/",
    val expires: Double = -1.0,
    val httpOnly: Boolean = false,
    val secure: Boolean = false,
) {
    /**
     * A leading dot is preserved or added so Android's CookieManager treats this
     * as a domain cookie covering the apex domain and all subdomains. Dropping it
     * means re-solving on every tab switch within a source.
     */
    fun toRawCookieString(requestHost: String): String = buildString {
        append("$name=$value")
        val dom = when {
            domain.isBlank() -> ".$requestHost"
            domain.startsWith('.') -> domain
            else -> ".$domain"
        }
        append("; Domain=$dom")
        append("; Path=$path")
        if (expires > 0) {
            val fmt = SimpleDateFormat("EEE, dd-MMM-yyyy HH:mm:ss z", Locale.US)
            fmt.timeZone = TimeZone.getTimeZone("GMT")
            append("; Expires=${fmt.format(Date((expires * 1000).toLong()))}")
        }
        if (secure) append("; Secure")
        if (httpOnly) append("; HttpOnly")
    }
}