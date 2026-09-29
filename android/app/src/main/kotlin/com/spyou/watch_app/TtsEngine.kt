package com.spyou.watch_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import android.util.Log
import java.util.Locale

/**
 * One speakable sentence plus the beat that follows it.
 *
 * Produced by the Dart `SentenceParser`, so the pause decision is made in one
 * place and unit-tested there rather than re-derived here.
 */
data class TtsUnit(val text: String, val pauseAfterMs: Int)

/**
 * The platform text-to-speech engine.
 *
 * Deliberately an [object] rather than something owned by the Flutter Activity:
 * speech has to outlive the reader screen (lockscreen playback, chapter
 * auto-advance), so the engine cannot have an Activity lifetime. The foreground
 * service added later takes over driving this same instance.
 *
 * ### Queuing
 * The engine is told the whole chapter up front and keeps [LOOKAHEAD] sentences
 * queued ahead of the one being spoken, refilling as each finishes. Handing the
 * engine one sentence at a time from Dart would stutter, because every round
 * trip is slower than the gap between sentences.
 *
 * Pauses use `playSilentUtterance` rather than a `Handler.postDelayed`. A timer
 * keeps running when the process is backgrounded or the device sleeps, whereas a
 * silent utterance stays on the engine's own timeline — so the beat after a
 * sentence is exactly as long when the screen is off as when it is on.
 *
 * ### Stale callbacks
 * `TextToSpeech` delivers progress callbacks asynchronously, and they keep
 * arriving after `stop()` for utterances that were already in flight. Left
 * alone, a callback from a previous chapter can move the highlight backwards
 * mid-sentence. Every utterance id therefore embeds a [generation] counter that
 * is bumped on every start/stop/pause, and any callback whose generation is not
 * current is dropped. Comparing indices instead is the common approach and it
 * breaks when the user restarts from the same sentence.
 */
object TtsEngine {
    private const val TAG = "TtsEngine"

    /** Sentences kept queued ahead of the current one. */
    private const val LOOKAHEAD = 3

    /** Pause before the first retry of a queue that was flushed a moment ago. */
    private const val FLUSH_RETRY_MS = 120L

    private const val KIND_SENTENCE = 's'
    private const val KIND_PAUSE = 'p'

    /** Events the owner (bridge, then service) reacts to. */
    interface Listener {
        /** Engine is usable. [status] is `TextToSpeech.SUCCESS` or `ERROR`. */
        fun onInit(status: Int)

        /** [index] started speaking. Drives the reader highlight. */
        fun onSentenceStart(index: Int)

        /** [index] finished, successfully or not. */
        fun onSentenceDone(index: Int)

        fun onError(index: Int, code: Int)

        fun onPaused(index: Int)

        fun onCompleted()

        fun onStopped()
    }

    private val main = Handler(Looper.getMainLooper())

    private var tts: TextToSpeech? = null
    private var ready = false
    private var listener: Listener? = null

    private var units: List<TtsUnit> = emptyList()
    private var generation = 0
    private var currentIndex = 0
    private var highestQueued = -1
    private var paused = false
    private var resumeIndex = 0

    /** Set when [start] was called before the engine finished initialising. */
    private var pendingStart: Int? = null
    private var retryPosted = false

    private var pendingVoice: String? = null
    private var pendingRate = 1.0f
    private var pendingPitch = 1.0f

    // ── lifecycle ────────────────────────────────────────────────────────────

    /**
     * Creates the engine if needed and reports readiness to [listener].
     *
     * Safe to call repeatedly: an already-initialised engine reports back
     * immediately rather than building a second one, because two `TextToSpeech`
     * instances on a device contend for the same engine service and produce
     * dropped audio.
     */
    fun initialize(context: Context, listener: Listener?) {
        this.listener = listener
        if (ready) {
            listener?.onInit(TextToSpeech.SUCCESS)
            return
        }
        if (tts != null) return // init already in flight

        tts = TextToSpeech(context.applicationContext) { status ->
            // `this@TtsEngine.listener`, not the captured parameter: a second
            // [initialize] can arrive while the first is still in flight, and
            // reporting readiness to the listener that asked first leaves the
            // one that is actually listening with an engine it never hears
            // about — narration that silently never starts.
            val current = this@TtsEngine.listener
            if (status == TextToSpeech.SUCCESS) {
                ready = true
                tts?.setOnUtteranceProgressListener(progress)
                applyPendingConfig()
                current?.onInit(TextToSpeech.SUCCESS)
                pendingStart?.let {
                    pendingStart = null
                    begin(it)
                }
            } else {
                // An engine that failed to init will never recover on this
                // device (no TTS data, or no engine at all). Say so once and stay
                // silent rather than throwing on every speak.
                ready = false
                Log.w(TAG, "TextToSpeech init failed: $status")
                current?.onInit(TextToSpeech.ERROR)
            }
        }
    }

    /** Tears the engine down. The next [initialize] builds a fresh one. */
    fun release() {
        generation++
        units = emptyList()
        pendingStart = null
        paused = false
        main.removeCallbacksAndMessages(null)
        tts?.run {
            setOnUtteranceProgressListener(null)
            stop()
            shutdown()
        }
        tts = null
        ready = false
        listener = null
    }

    fun isReady(): Boolean = ready

    // ── playback ─────────────────────────────────────────────────────────────

    /**
     * Speaks [units] from [startIndex].
     *
     * The full list is passed rather than a window so the queue can be refilled
     * without another round trip to Dart at the end of every sentence.
     */
    fun start(units: List<TtsUnit>, startIndex: Int) {
        if (units.isEmpty()) return
        val safeStart = startIndex.coerceIn(0, units.size - 1)
        this.units = units
        this.paused = false

        val engine = tts
        if (engine == null || !ready) {
            // Hold it until onInit; a reader can be opened and played before the
            // engine has finished starting.
            pendingStart = safeStart
            return
        }
        begin(safeStart)
    }

    private fun begin(from: Int) {
        val engine = tts ?: return
        // Invalidate anything already in flight before touching the queue.
        generation++
        currentIndex = from
        highestQueued = -1
        paused = false
        retryPosted = false
        engine.stop()
        enqueueFrom(from, allowRetry = true)
    }

    /**
     * Queues sentences from [from] until the look-ahead window is full.
     *
     * The bound is [from] + [LOOKAHEAD] + 1 sentences, computed up front rather
     * than tested against [highestQueued]. Deriving it from `highestQueued`
     * looks equivalent and is not: that field starts at -1 and then trails the
     * cursor by one, so `i > highestQueued + LOOKAHEAD` is false for every `i`
     * and the loop runs to the end of the chapter — queueing all several hundred
     * sentences in one burst. Beyond wasting the engine's queue, that is enough
     * pending synthesis to exhaust the binder and get audio dropped.
     *
     * A `speak` call can fail — most often because it raced a `stop()`, or the
     * device has no voice for the chapter's language. Either way the failure
     * must not end speech: the sentence is reported and the queue moves on. If
     * *every* one of them fails there is nothing left to trigger a completion
     * callback, so the chapter is finished explicitly instead of going quiet
     * forever.
     */
    private fun enqueueFrom(from: Int, allowRetry: Boolean) {
        val engine = tts ?: return
        if (!ready) return

        val limit = minOf(units.size, from + LOOKAHEAD + 1)
        var i = from
        var queuedAny = false
        while (i < limit) {
            if (tryEnqueue(engine, i)) {
                highestQueued = i
                queuedAny = true
            } else {
                Log.w(TAG, "could not queue sentence $i")
                listener?.onError(i, TextToSpeech.ERROR)
            }
            i++
        }

        if (queuedAny) return

        if (allowRetry && !retryPosted) {
            // Almost always the engine was still flushing a previous stop().
            retryPosted = true
            // Guarded by the generation it was posted under. That window is
            // 120ms wide and a stop, a seek or a chapter change can easily land
            // inside it — and the retry then re-runs against whatever `units` is
            // *now*, not the ones it was waiting for. With an empty list (a
            // stop) the loop does nothing, `queuedAny` is false, and it falls
            // straight through to finish(): a session the user had just stopped
            // announcing its own completion, which auto-advance then acts on by
            // turning the page and starting to read.
            val forGeneration = generation
            main.postDelayed({
                if (forGeneration != generation || units.isEmpty()) {
                    Log.i(TAG, "discarding a stale queue retry")
                    return@postDelayed
                }
                enqueueFrom(from, allowRetry = false)
            }, FLUSH_RETRY_MS)
        } else {
            finish()
        }
    }

    private fun tryEnqueue(engine: TextToSpeech, index: Int): Boolean {
        val unit = units.getOrNull(index) ?: return false
        val result = engine.speak(unit.text, TextToSpeech.QUEUE_ADD, null, idOf(KIND_SENTENCE, index))
        if (result != TextToSpeech.SUCCESS) return false

        // No trailing beat after the final sentence: it would be dead air before
        // the completion callback.
        if (index < units.size - 1 && unit.pauseAfterMs > 0) {
            engine.playSilentUtterance(
                unit.pauseAfterMs.toLong(),
                TextToSpeech.QUEUE_ADD,
                idOf(KIND_PAUSE, index),
            )
        }
        return true
    }

    /**
     * Stops playback and forgets the queue.
     *
     * This is the "user pressed stop" path and is not reversible.
     */
    fun stop() {
        generation++
        units = emptyList()
        pendingStart = null
        paused = false
        retryPosted = false
        tts?.stop()
        listener?.onStopped()
    }

    /**
     * Stops but remembers [currentIndex] so [resume] can pick it up.
     *
     * Android has no way to suspend an utterance part-way through, so resuming
     * re-speaks the current sentence from its beginning. Everything before it is
     * skipped, which is the only behaviour available and the one users expect
     * from an audiobook-style player.
     */
    fun pause() {
        if (units.isEmpty() || !ready) return
        paused = true
        resumeIndex = currentIndex
        generation++
        tts?.stop()
        listener?.onPaused(currentIndex)
    }

    fun resume() {
        if (!paused || units.isEmpty()) return
        val from = resumeIndex
        paused = false
        begin(from)
    }

    fun isPaused(): Boolean = paused

    /**
     * Jumps [delta] sentences within the loaded chapter.
     *
     * Exists so the notification's next/previous buttons can seek without going
     * back through a MethodChannel — a channel is bound to a live Flutter
     * engine, so once the reader screen is gone those buttons would be dead.
     *
     * When paused the position moves but nothing is queued, so a paused session
     * stays silent and the next Resume continues from the new sentence. Queueing
     * here would start speech the moment the user skipped past a chapter on a
     * paused player.
     */
    fun skip(delta: Int) {
        if (units.isEmpty() || !ready) return
        val target = (currentIndex + delta).coerceIn(0, units.size - 1)
        if (target == currentIndex) return

        if (paused) {
            generation++
            currentIndex = target
            resumeIndex = target
            highestQueued = -1
            tts?.stop()
            listener?.onPaused(target)
        } else {
            begin(target)
        }
    }

    fun currentIndex(): Int = currentIndex

    fun totalSentences(): Int = units.size

    private fun finish() {
        // Logged because "auto-advance does nothing" has two very different
        // causes that look identical from the UI: the engine never got here, or
        // it did and the page refused to turn. This line separates them.
        Log.i(TAG, "finish(): ${units.size} units, finishing at $currentIndex")
        tts?.stop()
        listener?.onCompleted()
    }

    // ── progress callbacks ───────────────────────────────────────────────────

    private val progress = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) {
            val id = decode(utteranceId) ?: return
            if (id.generation != generation) return
            if (id.kind == KIND_SENTENCE) {
                currentIndex = id.index
                listener?.onSentenceStart(id.index)
            }
        }

        override fun onDone(utteranceId: String?) {
            val id = decode(utteranceId) ?: return
            if (id.generation != generation) return
            if (id.kind != KIND_SENTENCE) return
            listener?.onSentenceDone(id.index)
            advance(id.index)
        }

        @Deprecated("Kept for engines that only report the single-argument form")
        override fun onError(utteranceId: String?) = onError(utteranceId, TextToSpeech.ERROR)

        override fun onError(utteranceId: String?, errorCode: Int) {
            val id = decode(utteranceId) ?: return
            if (id.generation != generation) return
            if (id.kind != KIND_SENTENCE) return
            // An error is also a completion: onDone is not called for a failed
            // utterance, so without this the queue would stop refilling and
            // speech would die mid-chapter instead of skipping one sentence.
            Log.w(TAG, "utterance ${id.index} failed: $errorCode")
            listener?.onError(id.index, errorCode)
            advance(id.index)
        }
    }

    /** Refills the look-ahead window, or finishes if that was the last sentence. */
    private fun advance(finishedIndex: Int) {
        if (finishedIndex >= units.size - 1) {
            finish()
            return
        }
        val engine = tts ?: return
        var i = maxOf(highestQueued + 1, finishedIndex + 1)
        while (i < units.size && i <= finishedIndex + LOOKAHEAD) {
            if (tryEnqueue(engine, i)) {
                highestQueued = i
            } else {
                listener?.onError(i, TextToSpeech.ERROR)
            }
            i++
        }
    }

    // ── utterance ids ────────────────────────────────────────────────────────

    private data class DecodedId(val generation: Int, val kind: Char, val index: Int)

    private fun idOf(kind: Char, index: Int): String = "g${generation}_$kind$index"

    private fun decode(raw: String?): DecodedId? {
        if (raw.isNullOrEmpty()) return null
        val sep = raw.indexOf('_')
        if (sep <= 1 || sep + 2 > raw.length) return null
        val gen = raw.substring(1, sep).toIntOrNull() ?: return null
        val index = raw.substring(sep + 2).toIntOrNull() ?: return null
        return DecodedId(gen, raw[sep + 1], index)
    }

    // ── configuration ────────────────────────────────────────────────────────

    /** Selects a voice by [Voice.getName], or clears the override when null. */
    fun setVoice(name: String?) {
        pendingVoice = name
        applyPendingConfig()
    }

    /**
     * Speech rate. Clamped: engines behave unpredictably outside this range, and
     * a slider that can reach 4x mostly produces noise.
     *
     * The upper bound matches TtsSpeed.max on the Dart side. It has to: the speed
     * button can offer 3x, and a clamp left at 2.0 here would show the user
     * "3x" while speaking at 2x — the one kind of TTS bug that sounds like a
     * broken app rather than a wrong number.
     */
    fun setRate(rate: Float) {
        pendingRate = rate.coerceIn(0.5f, 3.0f)
        applyPendingConfig()
    }

    fun setPitch(pitch: Float) {
        pendingPitch = pitch.coerceIn(0.5f, 2.0f)
        applyPendingConfig()
    }

    private fun applyPendingConfig() {
        val engine = tts ?: return
        if (!ready) return

        val voiceName = pendingVoice
        if (!voiceName.isNullOrEmpty()) {
            val voice: Voice? = engine.voices?.firstOrNull { it.name == voiceName }
            if (voice == null) {
                // The voice list can change when the user installs or removes
                // engine data. Fall back to the default rather than speaking
                // with the previous override silently.
                Log.w(TAG, "voice '$voiceName' unavailable; using default")
                engine.setLanguage(voice?.locale ?: Locale.getDefault())
            } else {
                if (engine.setVoice(voice) == TextToSpeech.SUCCESS) {
                    engine.setLanguage(voice.locale)
                }
            }
        }

        engine.setSpeechRate(pendingRate)
        engine.setPitch(pendingPitch)
    }

    /** Every voice the device offers, sorted for a stable picker. */
    fun voices(): List<Map<String, Any?>> {
        val engine = tts ?: return emptyList()
        val out = ArrayList<Map<String, Any?>>()
        val all = engine.voices ?: return emptyList()
        for (v in all) {
            out.add(
                mapOf(
                    "name" to v.name,
                    "locale" to v.locale.toLanguageTag(),
                    "quality" to v.quality,
                    "network" to v.isNetworkConnectionRequired,
                ),
            )
        }
        return out.sortedWith(
            compareBy({ it["locale"] as? String ?: "" }, { it["name"] as? String ?: "" }),
        )
    }

    /**
     * `TextToSpeech.isLanguageAvailable` for a BCP-47 [tag], so Dart can warn
     * about a chapter in a language this device has no voice for *before* the
     * user presses play.
     */
    fun languageStatus(tag: String): Int {
        val engine = tts ?: return TextToSpeech.ERROR
        return try {
            engine.isLanguageAvailable(Locale.forLanguageTag(tag))
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "bad language tag '$tag': ${e.message}")
            TextToSpeech.ERROR
        }
    }

    fun defaultLocale(): String = Locale.getDefault().toLanguageTag()
}
