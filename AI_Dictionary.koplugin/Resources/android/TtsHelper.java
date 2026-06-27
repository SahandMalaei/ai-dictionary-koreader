package org.koreader.plugin.audiobook;

import android.content.Context;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.os.Bundle;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;

import java.io.File;
import java.util.Locale;

/**
 * Minimal TTS helper for the KOReader audiobook plugin.
 *
 * Provides a polling-friendly API so Lua (via JNI) does not need to
 * implement Java callback interfaces.  All callbacks update volatile
 * status fields that Lua reads via getInitStatus() / getSynthStatus().
 */
public class TtsHelper implements TextToSpeech.OnInitListener {

    private TextToSpeech tts;
    private AudioManager audioManager;

    /** -1 = pending, 0 = SUCCESS, non-zero = error */
    private volatile int initStatus = -1;

    /** -1 = idle, 0 = in progress, 1 = done OK, 2 = error */
    private volatile int synthStatus = -1;

    // --- Synth-then-play pipeline state ---
    /** Pipeline status: -1=idle, 0=synthesizing, 1=playing, 2=done OK, 3=error */
    private volatile int pipelineStatus = -1;
    private volatile int pipelineDurationMs = 0;
    private volatile boolean pipelineActive = false;
    private volatile String pendingPlayFile = null;

    public TtsHelper(Context context) {
        tts = new TextToSpeech(context, this);
        audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
    }

    @Override
    public void onInit(int status) {
        initStatus = status;
        if (status == TextToSpeech.SUCCESS) {
            tts.setLanguage(Locale.US);
            tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
                @Override
                public void onStart(String utteranceId) {}

                @Override
                public void onDone(String utteranceId) {
                    synthStatus = 1;
                    // Pipeline mode: auto-start playback when synthesis finishes
                    if (pipelineActive && pendingPlayFile != null) {
                        String path = pendingPlayFile;
                        pendingPlayFile = null;
                        int dur = startPlayback(path);
                        if (dur >= 0) {
                            pipelineDurationMs = dur;
                            pipelineStatus = 1;  // playing
                        } else {
                            pipelineStatus = 3;  // error
                            pipelineActive = false;
                        }
                    }
                }

                @Override
                public void onError(String utteranceId) {
                    synthStatus = 2;
                    if (pipelineActive) {
                        pipelineStatus = 3;
                        pipelineActive = false;
                        pendingPlayFile = null;
                    }
                }
            });
        }
    }

    /** Returns -1 while TTS engine is loading, 0 on success, >0 on error. */
    public int getInitStatus() {
        return initStatus;
    }

    /**
     * Start async synthesis to a WAV file.
     * Returns 0 on successful dispatch, -1 if TTS not ready, >0 on error.
     */
    public int synthesizeToFile(String text, String filePath) {
        if (tts == null || initStatus != TextToSpeech.SUCCESS) {
            return -1;
        }
        synthStatus = 0;
        Bundle params = new Bundle();
        File file = new File(filePath);
        // Ensure parent directory exists
        File parent = file.getParentFile();
        if (parent != null && !parent.exists()) {
            parent.mkdirs();
        }
        try {
            // Use a unique utterance ID per call so the TTS engine treats
            // each request as distinct.  Some engines ignore onDone for
            // reused IDs.
            String uttId = "audiobook_" + System.currentTimeMillis();
            return tts.synthesizeToFile(text, params, file, uttId);
        } catch (Exception e) {
            synthStatus = 2;
            return -1;
        }
    }

    /** Returns -1 idle, 0 in-progress, 1 done, 2 error. */
    public int getSynthStatus() {
        return synthStatus;
    }

    /** Set speech rate (1.0 = normal). */
    public void setRate(float rate) {
        if (tts != null) {
            tts.setSpeechRate(rate);
        }
    }

    /** Set pitch (1.0 = normal). */
    public void setPitch(float pitch) {
        if (tts != null) {
            tts.setPitch(pitch);
        }
    }

    /** Set language by BCP-47 tag (e.g. "en-US"). */
    public int setLanguage(String bcp47) {
        if (tts == null) return -1;
        Locale locale = Locale.forLanguageTag(bcp47);
        int result = tts.setLanguage(locale);
        return result;
    }

    /** Release the TTS engine. */
    public void shutdown() {
        stopPipeline();
        if (tts != null) {
            tts.stop();
            tts.shutdown();
            tts = null;
        }
    }

    // --- Audio focus ---

    @SuppressWarnings("deprecation")
    private void requestAudioFocus() {
        if (audioManager != null) {
            audioManager.requestAudioFocus(null,
                AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN);
        }
    }

    @SuppressWarnings("deprecation")
    private void abandonAudioFocus() {
        if (audioManager != null) {
            audioManager.abandonAudioFocus(null);
        }
    }

    // --- Synth-then-play pipeline ---

    /**
     * Start a combined synthesize-then-play pipeline.
     * Synthesis runs asynchronously; when complete, playback starts
     * automatically on the Java side (no Lua polling needed for the
     * synth-to-play transition).
     * Returns 0 on successful dispatch, -1 if TTS not ready, >0 on error.
     */
    public int synthesizeAndPlay(String text, String filePath) {
        if (tts == null || initStatus != TextToSpeech.SUCCESS) return -1;

        // Stop any current pipeline/playback
        stopPipeline();

        pipelineActive = true;
        pipelineStatus = 0;  // synthesizing
        pipelineDurationMs = 0;
        pendingPlayFile = filePath;
        synthStatus = 0;

        File file = new File(filePath);
        File parent = file.getParentFile();
        if (parent != null && !parent.exists()) parent.mkdirs();

        try {
            String uttId = "pipeline_" + System.currentTimeMillis();
            int result = tts.synthesizeToFile(text, new Bundle(), file, uttId);
            if (result != TextToSpeech.SUCCESS) {
                pipelineStatus = 3;
                pipelineActive = false;
                pendingPlayFile = null;
                return result;
            }
            return 0;
        } catch (Exception e) {
            pipelineStatus = 3;
            pipelineActive = false;
            pendingPlayFile = null;
            return -1;
        }
    }

    /** Pipeline status: -1=idle, 0=synthesizing, 1=playing, 2=done OK, 3=error. */
    public int getPipelineStatus() {
        return pipelineStatus;
    }

    /** Playback duration in ms (available once pipeline reaches status 1). */
    public int getPipelineDurationMs() {
        return pipelineDurationMs;
    }

    /** Cancel the pipeline (synthesis and/or playback) and release audio focus. */
    public void stopPipeline() {
        pendingPlayFile = null;
        boolean wasSynthesizing = pipelineActive && pipelineStatus == 0;
        pipelineActive = false;
        pipelineStatus = -1;
        pipelineDurationMs = 0;
        if (wasSynthesizing && tts != null) {
            tts.stop();
        }
        stopPlayback();
    }

    // --- Audio playback via MediaPlayer ---

    private final Object mpLock = new Object();
    private MediaPlayer mediaPlayer;
    private volatile boolean playbackDone = false;

    /**
     * Play a WAV file through the default audio output.
     * If a pipeline is active, it is cancelled first (direct playFile
     * implies the caller is bypassing the pipeline).
     * Returns the duration in ms, or -1 on error.
     */
    public int playFile(String path) {
        if (pipelineActive) {
            pipelineActive = false;
            pipelineStatus = -1;
            pipelineDurationMs = 0;
            pendingPlayFile = null;
        }
        return startPlayback(path);
    }

    /**
     * Internal: start MediaPlayer on a file.  Used by both playFile()
     * (direct) and the pipeline's auto-play callback.
     */
    private int startPlayback(String path) {
        stopPlayback();
        playbackDone = false;
        requestAudioFocus();
        synchronized (mpLock) {
            try {
                mediaPlayer = new MediaPlayer();
                mediaPlayer.setDataSource(path);
                mediaPlayer.setVolume(1.0f, 1.0f);
                mediaPlayer.setOnCompletionListener(mp -> {
                    playbackDone = true;
                    if (pipelineActive) {
                        pipelineStatus = 2;
                        pipelineActive = false;
                    }
                    abandonAudioFocus();
                });
                mediaPlayer.setOnErrorListener((mp, what, extra) -> {
                    playbackDone = true;
                    if (pipelineActive) {
                        pipelineStatus = 3;
                        pipelineActive = false;
                    }
                    abandonAudioFocus();
                    return true;
                });
                mediaPlayer.prepare();
                mediaPlayer.start();
                return mediaPlayer.getDuration();
            } catch (Exception e) {
                playbackDone = true;
                if (pipelineActive) {
                    pipelineStatus = 3;
                    pipelineActive = false;
                }
                abandonAudioFocus();
                if (mediaPlayer != null) {
                    try { mediaPlayer.release(); } catch (Exception ignored) {}
                    mediaPlayer = null;
                }
                return -1;
            }
        }
    }

    /** Check if audio is still playing. */
    public boolean isPlaying() {
        synchronized (mpLock) {
            try {
                return mediaPlayer != null && mediaPlayer.isPlaying();
            } catch (IllegalStateException e) {
                return false;
            }
        }
    }

    /** Check if playback finished (completed or error). */
    public boolean isPlaybackDone() {
        return playbackDone;
    }

    /** Stop and release the MediaPlayer. */
    public void stopPlayback() {
        synchronized (mpLock) {
            if (mediaPlayer != null) {
                // Clear listeners BEFORE release to prevent callbacks from
                // firing on the internal thread after the native object is
                // destroyed (causes pthread_mutex_lock on destroyed mutex).
                mediaPlayer.setOnCompletionListener(null);
                mediaPlayer.setOnErrorListener(null);
                try {
                    if (mediaPlayer.isPlaying()) {
                        mediaPlayer.stop();
                    }
                } catch (IllegalStateException ignored) {}
                try {
                    mediaPlayer.release();
                } catch (Exception ignored) {}
                mediaPlayer = null;
            }
            playbackDone = false;
        }
        abandonAudioFocus();
    }

    /** Pause audio playback. */
    public void pausePlayback() {
        synchronized (mpLock) {
            try {
                if (mediaPlayer != null && mediaPlayer.isPlaying()) {
                    mediaPlayer.pause();
                }
            } catch (IllegalStateException ignored) {}
        }
    }

    /** Resume audio playback after pause. */
    public void resumePlayback() {
        synchronized (mpLock) {
            try {
                if (mediaPlayer != null && !mediaPlayer.isPlaying()) {
                    mediaPlayer.start();
                }
            } catch (IllegalStateException ignored) {}
        }
    }
}
