package com.spyou.watch_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Foreground service that keeps read-aloud alive and controllable while the app
 * is in the background.
 *
 * The process is the thing that actually dies when a reader screen is closed and
 * the app is swiped away, taking the `TextToSpeech` engine and its queue with
 * it. A foreground service is the only supported way to stop that, and it is
 * also what the user sees: a lockscreen notification with transport controls,
 * which is how anyone expects to control a long audiobook-style narration.
 *
 * ### It owns no narration logic
 * Sentence queueing, pacing and stale-callback handling all live in
 * [TtsEngine]. This service only does the three things that must outlive the
 * Flutter engine: hold the process in the foreground, hold a wakelock so the
 * CPU keeps running with the screen off, and own audio focus.
 *
 * ### Notification buttons act on the engine directly
 * The buttons call [TtsEngine] rather than going through a MethodChannel back to
 * Dart. A method channel is bound to a live Flutter engine, so a notification
 * tap that routes through Dart silently does nothing once the reader screen is
 * gone — the worst possible failure for a control the user can see but not use.
 * Dart drives the same singleton, so both paths converge on one state.
 */
class TtsService : Service() {

    private var session: MediaSessionCompat? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var focusRequest: AudioFocusRequest? = null
    private var hasFocus = false

    /** Set while a pause came from another app taking focus, so we can tell it
     *  apart from the user pressing pause and don't fight them for the speaker. */
    private var pausedForFocusLoss = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannel()
        session = MediaSessionCompat(this, "ZangetsuTts").apply {
            setCallback(
                object : MediaSessionCompat.Callback() {
                    override fun onPlay() = resumeFromNotification()
                    override fun onPause() = pauseFromNotification()
                    override fun onStop() = stopFromNotification()

                    // A headset's next/previous, and the fast-forward/rewind a
                    // Bluetooth remote sends for the same intent, move one
                    // sentence — the same granularity as the notification's own
                    // buttons, so the key and the on-screen control agree.
                    //
                    // Chapter-level skipping is deliberately not here: the chapter
                    // list lives in Dart, and a media key that worked only while
                    // the reader happened to be open would be worse than one that
                    // is absent.
                    override fun onSkipToNext() = skipFromNotification(1)
                    override fun onSkipToPrevious() = skipFromNotification(-1)
                    override fun onFastForward() = skipFromNotification(1)
                    override fun onRewind() = skipFromNotification(-1)

                    /**
                     * A seek needs a position the engine does not expose over
                     * this path, and guessing one from a key press would move
                     * the highlight to words nobody asked for. Declared
                     * supported so the system UI offers it, and answered with
                     * the current sentence's own position, which makes the scrub
                     * a no-op instead of a jump.
                     */
                    override fun onSeekTo(pos: Long) {
                        updateNotification()
                    }
                },
            )
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            // The headset/Bluetooth key path. `MediaButtonReceiver` decodes the
            // KeyEvent and calls the session callback above, so a key press is
            // handled by exactly the same code as tapping the notification.
            Intent.ACTION_MEDIA_BUTTON -> {
                val current = session
                if (current != null) {
                    androidx.media.session.MediaButtonReceiver.handleIntent(current, intent)
                }
            }
            ACTION_STOP -> {
                stopEverything()
                return START_NOT_STICKY
            }
            ACTION_PAUSE -> pauseFromNotification()
            ACTION_RESUME -> resumeFromNotification()
            ACTION_NEXT -> skipFromNotification(1)
            ACTION_PREVIOUS -> skipFromNotification(-1)
            else -> {
                startForegroundCompat(buildNotification())
                markRunning(true)
                acquireWakeLock()
                requestAudioFocus()
                updateNotification()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        abandonAudioFocus()
        markRunning(false)
        instance = null
        session?.isActive = false
        session?.release()
        session = null
        super.onDestroy()
    }

    /**
     * Swiping the app out of the task switcher ends the narration.
     *
     * ### Why the background features survive this
     *
     * Everything else the app does in the background — the home button, another
     * app in front, the screen off, the lock screen, a headset key — leaves the
     * task in place, so none of it comes through here and all of it keeps
     * reading. What this callback catches is the one gesture that means "I am
     * finished with this app": the card is thrown away.
     *
     * Leaving the voice running after that is worse than the absence of a
     * feature. There is no screen, no panel and no chapter behind it any more,
     * so the only things that can stop it are the notification or the lock
     * screen — and a reader who swipes a task away is not looking for either.
     * It reads as the app refusing to be closed, and the cure nobody knows about
     * is the one control nobody can reach.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        // Same path as the notification's stop button, so the queue, the wake
        // lock, the audio focus, the session and the notification all end
        // together — stopping only the engine would leave a foreground
        // notification claiming something is playing.
        stopEverything()
        super.onTaskRemoved(rootIntent)
    }

    // ── foreground / wakelock ────────────────────────────────────────────────

    private fun startForegroundCompat(n: Notification) {
        if (Build.VERSION.SDK_INT >= 34) {
            // API 34 requires the declared type, and mediaPlayback is the honest
            // one: this really is audio playback, and DATA_SYNC would be a lie
            // that Play Store review rejects.
            startForeground(NOTI_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTI_ID, n)
        }
    }

    /**
     * Holds the CPU awake so synthesis continues with the screen off.
     *
     * A partial wakelock, and only while actually narrating: `PARTIAL_WAKE_LOCK`
     * costs battery, and holding one for a paused session would be a slow leak
     * of the user's battery for no benefit.
     */
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_TAG).apply {
            setReferenceCounted(false)
            // Bounded so a wedged engine cannot hold the CPU awake indefinitely.
            acquire(MAX_WAKELOCK_MS)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    // ── audio focus ──────────────────────────────────────────────────────────

    private fun requestAudioFocus() {
        if (hasFocus) return
        val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        hasFocus = if (Build.VERSION.SDK_INT >= 26) {
            val attrs = AudioAttributes.Builder()
                // USAGE_MEDIA rather than USAGE_ASSISTANCE: a novel read aloud is
                // media, and some devices route assistance output somewhere the
                // user is not listening to.
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attrs)
                .setOnAudioFocusChangeListener(focusListener)
                // Resume only for a loss the system will give back (a phone
                // call). For a permanent loss the user has to press play, so a
                // notification cannot later start speech the user did not ask
                // for.
                .setWillPauseWhenDucked(false)
                .build()
            focusRequest = request
            am.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                // Permanent: another app owns audio now and we will not get it
                // back automatically.
                pausedForFocusLoss = false
                if (TtsEngine.isPaused()) Unit else TtsEngine.pause()
                updateNotification()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // Temporary (a notification, a short video). Remember that WE
                // did not choose to stop, so focus coming back can resume us.
                if (TtsEngine.isPaused()) {
                    Unit
                } else {
                    pausedForFocusLoss = true
                    TtsEngine.pause()
                    updateNotification()
                }
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> Unit
            AudioManager.AUDIOFOCUS_GAIN -> {
                if (pausedForFocusLoss) {
                    pausedForFocusLoss = false
                    TtsEngine.resume()
                    updateNotification()
                }
            }
        }
    }

    private fun abandonAudioFocus() {
        if (!hasFocus) return
        hasFocus = false
        val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        if (Build.VERSION.SDK_INT >= 26) {
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            @Suppress("DEPRECATION")
            am.abandonAudioFocus(focusListener)
        }
    }

    // ── notification ─────────────────────────────────────────────────────────

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL) != null) return
        // LOW importance: this must never buzz or float over what the user is
        // reading. It is a transport control, not an alert.
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL,
                "Read aloud",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    private fun buildNotification(): Notification {
        val speaking = TtsEngine.isPaused().not()
        val builder = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(title)
            .setContentText(subtitle)
            .setSubText(if (speaking) "Reading" else "Paused")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setContentIntent(contentIntent())
            .addAction(
                NotificationCompat.Action(
                    android.R.drawable.ic_media_previous,
                    "Previous sentence",
                    servicePendingIntent(ACTION_PREVIOUS, REQ_PREVIOUS),
                ),
            )

        if (speaking) {
            builder.addAction(
                NotificationCompat.Action(
                    android.R.drawable.ic_media_pause,
                    "Pause",
                    servicePendingIntent(ACTION_PAUSE, REQ_PLAY_PAUSE),
                ),
            )
        } else {
            builder.addAction(
                NotificationCompat.Action(
                    android.R.drawable.ic_media_play,
                    "Resume",
                    servicePendingIntent(ACTION_RESUME, REQ_PLAY_PAUSE),
                ),
            )
        }

        builder.addAction(
            NotificationCompat.Action(
                android.R.drawable.ic_media_next,
                "Next sentence",
                servicePendingIntent(ACTION_NEXT, REQ_NEXT),
            ),
        )
        builder.addAction(
            NotificationCompat.Action(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Stop",
                servicePendingIntent(ACTION_STOP, REQ_STOP),
            ),
        )

        session?.let {
            builder.setStyle(
                androidx.media.app.NotificationCompat.MediaStyle()
                    .setMediaSession(it.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2),
            )
        }
        return builder.build()
    }

    /** Opens the app where the user left off, rather than a bare launcher icon. */
    private fun contentIntent(): PendingIntent? {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            this,
            REQ_CONTENT,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun servicePendingIntent(action: String, requestCode: Int): PendingIntent =
        PendingIntent.getService(
            this,
            requestCode,
            Intent(this, TtsService::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    // ── notification-driven transport ────────────────────────────────────────

    private fun pauseFromNotification() {
        TtsEngine.pause()
        updateNotification()
    }

    private fun resumeFromNotification() {
        TtsEngine.resume()
        requestAudioFocus()
        acquireWakeLock()
        updateNotification()
    }

    /** Shared by the notification buttons and the media keys. */
    private fun skipFromNotification(delta: Int) {
        TtsEngine.skip(delta)
        updateNotification()
    }

    private fun stopFromNotification() = stopEverything()

    private fun stopEverything() {
        TtsEngine.stop()
        releaseWakeLock()
        abandonAudioFocus()
        updateNotification()
        stopForegroundCompat()
        markRunning(false)
        stopSelf()
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    // ── bridge API ───────────────────────────────────────────────────────────

    private fun notifyManager() = getSystemService(NotificationManager::class.java)

    private fun updateNotification() {
        val nm = notifyManager() ?: return
        nm.notify(NOTI_ID, buildNotification())
        syncSession()
    }

    /**
     * Republishes the session's metadata and playback state.
     *
     * ### This has to run on every state change, including Dart's
     *
     * Android decides which app owns the media buttons by looking at the
     * sessions' playback states and picks the one that is *playing*. So a session
     * that is still advertising `PAUSED` while the engine speaks is not a cosmetic
     * inconsistency: the system keeps handing the headset keys to whatever app it
     * last saw playing, and this app's own pause/play buttons are unreachable
     * from the lock screen and from a pair of headphones.
     *
     * That is exactly what happened when only the service's own actions updated
     * the state: pause the narration with the panel, press play in the app, and
     * the session never left `PAUSED`, because the only other caller — [refresh],
     * on the path Dart uses for every sentence — rebuilt the notification and
     * nothing else.
     */
    private fun syncSession() {
        val current = session ?: return
        current.setMetadata(
            MediaMetadataCompat.Builder()
                // The system's media panel — the one under the shade, and the one
                // a car head unit or a watch shows — reads the session, not the
                // notification. Without metadata it lists the app and nothing
                // else, which is how a media app ends up as a nameless row.
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
                .putString(
                    MediaMetadataCompat.METADATA_KEY_ARTIST,
                    if (subtitle.isNotEmpty()) subtitle else "Reading aloud",
                )
                .putString(
                    MediaMetadataCompat.METADATA_KEY_ALBUM,
                    "Read aloud",
                )
                .build(),
        )
        current.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    // Every control the notification shows. Advertising them is
                    // not cosmetic: a system media UI, a car head unit and a
                    // Bluetooth remote all read this list and grey out whatever
                    // is missing, so leaving the skip actions out made a working
                    // control look unavailable on half the devices that can
                    // drive it.
                    PlaybackStateCompat.ACTION_PLAY or
                        PlaybackStateCompat.ACTION_PAUSE or
                        PlaybackStateCompat.ACTION_PLAY_PAUSE or
                        PlaybackStateCompat.ACTION_STOP or
                        PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                        PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                        PlaybackStateCompat.ACTION_FAST_FORWARD or
                        PlaybackStateCompat.ACTION_REWIND or
                        PlaybackStateCompat.ACTION_SEEK_TO,
                )
                .setState(
                    if (TtsEngine.isPaused()) PlaybackStateCompat.STATE_PAUSED
                    else PlaybackStateCompat.STATE_PLAYING,
                    // 0, because the unit is a sentence and the engine's clock
                    // is not a playback position. A real position here makes
                    // system UIs draw a scrubber that jumps to the wrong place.
                    0,
                    1.0f,
                )
                .setExtras(
                    android.os.Bundle().apply {
                        putInt("index", TtsEngine.currentIndex())
                        putInt("total", TtsEngine.totalSentences())
                    },
                )
                .build(),
        )
    }

    companion object {
        private const val CHANNEL = "tts_read_aloud"
        private const val NOTI_ID = 4202
        private const val WAKE_TAG = "zangetsu:tts"

        /** Upper bound on CPU wake, so a wedged engine cannot drain the battery. */
        private const val MAX_WAKELOCK_MS = 6 * 60 * 60 * 1000L

        const val ACTION_STOP = "com.spyou.watch_app.tts.STOP"
        const val ACTION_PAUSE = "com.spyou.watch_app.tts.PAUSE"
        const val ACTION_RESUME = "com.spyou.watch_app.tts.RESUME"
        const val ACTION_NEXT = "com.spyou.watch_app.tts.NEXT"
        const val ACTION_PREVIOUS = "com.spyou.watch_app.tts.PREVIOUS"

        private const val REQ_CONTENT = 10
        private const val REQ_PLAY_PAUSE = 11
        private const val REQ_NEXT = 12
        private const val REQ_PREVIOUS = 13
        private const val REQ_STOP = 14

        /** Label shown in the notification. */
        var title: String = "Reading aloud"
            private set

        /** The sentence being read, shown as the notification's second line. */
        var subtitle: String = ""
            private set

        fun setContent(title: String, subtitle: String) {
            this.title = title
            this.subtitle = subtitle
        }

        /** Starts the foreground service, creating it if needed. */
        fun start(context: Context) {
            val intent = Intent(context, TtsService::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, TtsService::class.java).setAction(ACTION_STOP),
            )
        }

        /**
         * Rebuilds the notification from the current [title]/[subtitle].
         *
         * Needs the live instance because the notification is built from service
         * state (wakelock, session, paused flag), not just the static text. A
         * no-op when the service is not running, so the caller does not have to
         * check first.
         *
         * Also republishes the session, and that matters more than it looks: this
         * is the path Dart takes for every sentence, and it is the only place
         * that notices a play or pause the user made in the app. A session whose
         * playback state is stale is a session the system will not route media
         * buttons to. See [syncSession].
         */
        fun refresh(context: Context) {
            if (!isRunning) return
            val running = instance ?: return
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            nm.notify(NOTI_ID, running.buildNotification())
            running.syncSession()
        }

        /**
         * Sends [action] to a running service.
         *
         * Silently does nothing if the service is not running: a next/previous
         * tap after narration already stopped is not an error worth surfacing.
         */
        fun send(context: Context, action: String) {
            if (action != ACTION_STOP && !isRunning) return
            runCatching {
                context.startService(
                    Intent(context, TtsService::class.java).setAction(action),
                )
            }.onFailure { Log.w("TtsService", "could not send $action: ${it.message}") }
        }

        /** True while the foreground notification is showing. */
        @Volatile
        var isRunning: Boolean = false
            private set

        internal fun markRunning(running: Boolean) {
            isRunning = running
        }

        /** The live service, for [refresh]. Null when not running. */
        @Volatile
        private var instance: TtsService? = null
    }
}
