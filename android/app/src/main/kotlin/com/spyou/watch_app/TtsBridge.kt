package com.spyou.watch_app

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Dart to [TtsEngine] over `zangetsu/tts`, with engine events on
 * `zangetsu/tts_events`.
 *
 * An object with `register`/`dispose` so MainActivity gains two lines, matching
 * the other bridges in this app.
 *
 * The channel is a thin argument translator on purpose. Sequencing, queue
 * refilling and stale-callback handling all live in [TtsEngine], which is where
 * they can be reasoned about without a Flutter engine attached; if they were
 * here, every one of those bugs would only be reachable on a device.
 */
object TtsBridge : TtsEngine.Listener {
    private const val TAG = "TtsBridge"
    private const val CHANNEL = "zangetsu/tts"
    private const val EVENT_CHANNEL = "zangetsu/tts_events"

    /** Where every event is delivered from. See [emit]. */
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var events: EventChannel.EventSink? = null

    fun register(engine: FlutterEngine, activity: Activity) {
        val messenger = engine.dartExecutor.binaryMessenger

        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    events = sink
                }

                override fun onCancel(arguments: Any?) {
                    events = null
                }
            },
        )

        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                handle(activity, call, result)
            } catch (e: Exception) {
                // A throw here would surface as a channel error and take the
                // isolate's error handler with it; log and report instead.
                Log.w(TAG, "${call.method} failed: ${e.message}")
                result.error("tts_error", e.message, null)
            }
        }
    }

    fun dispose() {
        events = null
    }

    private fun handle(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "init" -> {
                TtsEngine.initialize(context, this)
                result.success(null)
            }

            "start" -> {
                val units = parseUnits(call.argument<List<Map<String, Any?>>>("units"))
                if (units.isEmpty()) {
                    result.error("empty", "No sentences to speak", null)
                    return
                }
                val startIndex = (call.argument<Number>("startIndex") ?: 0).toInt()
                TtsEngine.start(units, startIndex)
                result.success(null)
            }

            "stop" -> {
                TtsEngine.stop()
                result.success(null)
            }

            "pause" -> {
                TtsEngine.pause()
                result.success(null)
            }

            "resume" -> {
                TtsEngine.resume()
                result.success(null)
            }

            "setVoice" -> {
                TtsEngine.setVoice(call.argument<String>("name"))
                result.success(null)
            }

            "setRate" -> {
                TtsEngine.setRate((call.argument<Number>("rate") ?: 1.0).toFloat())
                result.success(null)
            }

            "setPauseScale" -> {
                val scale = (call.argument<Number>("scale") ?: 1.0).toDouble()
                TtsEngine.setPauseScale(scale)
                result.success(null)
            }

            "setPitch" -> {
                TtsEngine.setPitch((call.argument<Number>("pitch") ?: 1.0).toFloat())
                result.success(null)
            }

            "voices" -> result.success(TtsEngine.voices())

            "languageStatus" -> {
                val tag = call.argument<String>("tag")
                if (tag.isNullOrEmpty()) {
                    result.error("bad_args", "tag is required", null)
                    return
                }
                result.success(TtsEngine.languageStatus(tag))
            }

            "defaultLocale" -> result.success(TtsEngine.defaultLocale())

            "isReady" -> result.success(TtsEngine.isReady())

            // ── foreground service ──
            // Started when narration begins so it survives the reader closing,
            // and stopped when it ends. `title`/`sentence` become the
            // notification's two lines, which is how the user knows what is
            // being read without unlocking anything.
            "startService" -> {
                TtsService.setContent(
                    call.argument<String>("title") ?: "Reading aloud",
                    call.argument<String>("sentence") ?: "",
                )
                TtsService.start(context)
                result.success(null)
            }

            "updateService" -> {
                TtsService.setContent(
                    call.argument<String>("title") ?: "Reading aloud",
                    call.argument<String>("sentence") ?: "",
                )
                TtsService.refresh(context)
                result.success(null)
            }

            "stopService" -> {
                TtsService.stop(context)
                result.success(null)
            }

            "serviceRunning" -> result.success(TtsService.isRunning)

            else -> result.notImplemented()
        }
    }

    /**
     * Reads the sentence list sent by Dart.
     *
     * Entries that are missing text are dropped rather than queued as blanks,
     * because a blank utterance makes some engines emit a click and, worse,
     * shifts every later sentence's index by one.
     */
    private fun parseUnits(raw: List<Map<String, Any?>>?): List<TtsUnit> {
        if (raw.isNullOrEmpty()) return emptyList()
        val out = ArrayList<TtsUnit>(raw.size)
        for (item in raw) {
            val text = item["text"] as? String ?: continue
            if (text.isBlank()) continue
            val pause = (item["pauseAfterMs"] as? Number)?.toInt() ?: 0
            out.add(TtsUnit(text, pause.coerceIn(0, 2_000)))
        }
        return out
    }

    // ── TtsEngine.Listener → Dart events ────────────────────────────────────

    override fun onInit(status: Int) {
        emit(
            mapOf(
                "type" to "init",
                "ready" to (status == TextToSpeech.SUCCESS),
            ),
        )
    }

    override fun onSentenceStart(index: Int) {
        emit(mapOf("type" to "sentenceStart", "index" to index))
    }

    override fun onSentenceDone(index: Int) {
        emit(mapOf("type" to "sentenceDone", "index" to index))
    }

    override fun onError(index: Int, code: Int) {
        emit(mapOf("type" to "error", "index" to index, "code" to code))
    }

    override fun onPaused(index: Int) {
        emit(mapOf("type" to "paused", "index" to index))
    }

    override fun onResumed() {
        emit(mapOf("type" to "resumed"))
    }

    override fun onCompleted() {
        emit(mapOf("type" to "completed"))
    }

    override fun onStopped() {
        emit(mapOf("type" to "stopped"))
    }

    /**
     * Sends one event to Dart.
     *
     * ### Posted to the main thread, and it has to be
     *
     * `EventSink.success` is `@UiThread`. `UtteranceProgressListener` callbacks
     * arrive on a **binder** thread, so calling the sink directly throws
     * `IllegalStateException` and the event is lost.
     *
     * That failure is silent from the outside and breaks everything downstream
     * at once: audio plays, but no `sentenceStart` ever arrives, so Dart's
     * current index stays on 0 — no highlight ever moves, the panel keeps
     * quoting the first sentence while the voice is somewhere else entirely,
     * and `completed` is dropped the same way, so auto-advance never runs. The
     * symptom reads as three unrelated UI bugs; it is one dropped event.
     *
     * `post` is FIFO, so sentence start/done/completed still arrive in order.
     *
     * No sink means the reader is closed, which is normal during teardown, and
     * must not be logged as an error.
     */
    private fun emit(event: Map<String, Any?>) {
        val sink = events ?: return
        mainHandler.post {
            try {
                sink.success(event)
            } catch (e: Exception) {
                Log.w(TAG, "event ${event["type"]} dropped: ${e.message}")
            }
        }
    }
}

