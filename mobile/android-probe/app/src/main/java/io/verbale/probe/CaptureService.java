package io.verbale.probe;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.media.*;
import android.media.projection.*;
import android.os.*;
import org.json.*;
import java.io.File;
import java.util.*;

public final class CaptureService extends Service {
    static final String START = "io.verbale.probe.START", STOP = "io.verbale.probe.STOP";
    static final int MIC = 0, RECOGNITION = 1, PLAYBACK = 2;
    static final String[] MODE_NAMES = {"Microfono · MIC", "Microfono · VOICE_RECOGNITION", "Audio interno · MediaProjection"};
    static final int RATE = 16000;
    static final long LIMIT_MS = 120000;
    static volatile Snapshot snapshot = new Snapshot(false, "Pronto per una prova", 0, -120);
    static final class Snapshot {
        final boolean active; final String message; final long seconds; final double rms;
        Snapshot(boolean active, String message, long seconds, double rms) { this.active = active; this.message = message; this.seconds = seconds; this.rms = rms; }
    }
    private final Handler handler = new Handler(Looper.getMainLooper());
    private volatile boolean running;
    private volatile AudioRecord recorder;
    private volatile String stopReason = "Arresto richiesto";
    private MediaProjection projection;
    private PowerManager.WakeLock wakeLock;
    private boolean started;
    private volatile boolean destroyed;
    private volatile Snapshot completion;
    private final Runnable timeout = () -> requestStop("Limite della prova: 2 minuti");

    @Override public IBinder onBind(Intent intent) { return null; }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) { stopSelf(); return START_NOT_STICKY; }
        if (STOP.equals(intent.getAction())) {
            // A stop sent after the process died recreates an idle service: end it instead of leaving it alive.
            if (started) requestStop("Arresto richiesto"); else stopSelf();
            return START_NOT_STICKY;
        }
        if (!START.equals(intent.getAction()) || started) return START_NOT_STICKY;
        started = true;
        int mode = intent.getIntExtra("mode", MIC);
        if (mode < 0 || mode >= MODE_NAMES.length) { stopSelf(); return START_NOT_STICKY; }
        String scenario = intent.getStringExtra("scenario");
        snapshot = new Snapshot(true, "Preparazione · " + MODE_NAMES[mode], 0, -120);
        try {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) throw new SecurityException("Permesso microfono assente");
            NotificationManager manager = getSystemService(NotificationManager.class);
            manager.createNotificationChannel(new NotificationChannel("capture", "Prove audio di Verbale", NotificationManager.IMPORTANCE_LOW));
            PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
            PendingIntent stop = PendingIntent.getService(this, 1, new Intent(this, CaptureService.class).setAction(STOP), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
            Notification notification = new Notification.Builder(this, "capture").setSmallIcon(R.drawable.ic_mic)
                .setContentTitle("Verbale · prova audio in corso").setContentText(MODE_NAMES[mode]).setContentIntent(open)
                .setOngoing(true).addAction(new Notification.Action.Builder(null, "Termina", stop).build()).build();
            int type = mode == PLAYBACK ? ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION : (Build.VERSION.SDK_INT >= 30 ? ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE : 0);
            startForeground(1, notification, type);
            if (mode == PLAYBACK) {
                Intent data = Build.VERSION.SDK_INT >= 33 ? intent.getParcelableExtra("projectionData", Intent.class) : intent.getParcelableExtra("projectionData");
                if (data == null) throw new IllegalStateException("Condivisione audio non autorizzata");
                projection = getSystemService(MediaProjectionManager.class).getMediaProjection(intent.getIntExtra("resultCode", 0), data);
                if (projection == null) throw new IllegalStateException("Token MediaProjection non disponibile");
                projection.registerCallback(new MediaProjection.Callback() {
                    @Override public void onStop() { requestStop("Condivisione terminata da Android"); }
                }, handler);
            }
            wakeLock = getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "verbale:audio-probe");
            wakeLock.acquire(LIMIT_MS + 30000);
            running = true; handler.postDelayed(timeout, LIMIT_MS);
            new Thread(() -> capture(mode, scenario == null ? "Non specificato" : scenario, intent.getStringExtra("listeningRoute")), "verbale-audio-probe").start();
        } catch (Exception error) {
            running = false;
            String message = "Avvio non riuscito: " + error.getClass().getSimpleName() + " · " + error.getMessage();
            completion = new Snapshot(false, message, 0, -120);
            try {
                File folder = new File(SessionFiles.root(this), UUID.randomUUID().toString());
                if (folder.mkdir()) SessionFiles.save(folder, new JSONObject().put("schema", 1).put("state", "failed")
                    .put("startedAtEpochMs", System.currentTimeMillis()).put("model", Build.MODEL).put("androidSdk", Build.VERSION.SDK_INT)
                    .put("mode", MODE_NAMES[mode]).put("scenario", scenario).put("error", message));
            } catch (Exception ignored) { /* Error remains visible even if private storage is unavailable. */ }
            stopSelf();
        }
        return START_NOT_STICKY;
    }
    @android.annotation.SuppressLint("MissingPermission") // Permission is checked before the worker is started; revocation is caught and persisted.
    private void capture(int mode, String scenario, String listeningRoute) {
        File folder = new File(new File(getFilesDir(), "probes"), UUID.randomUUID().toString());
        JSONObject metadata = new JSONObject(); JSONArray events = new JSONArray(); SignalStats stats = new SignalStats();
        long startedAt = System.currentTimeMillis(), origin = SystemClock.elapsedRealtime(), lastCheckpoint = origin;
        int silencedChecks = 0, configChecks = 0, previousMode = -1; Boolean previousSilenced = null;
        String errorMessage = null; boolean initialized = false;
        AudioManager audioManager = getSystemService(AudioManager.class);
        try {
            SessionFiles.root(this);
            if (!folder.mkdir()) throw new IllegalStateException("Impossibile creare la cartella della prova");
            metadata.put("schema", 1).put("startedAtEpochMs", startedAt).put("manufacturer", Build.MANUFACTURER).put("model", Build.MODEL)
                .put("androidRelease", Build.VERSION.RELEASE).put("androidSdk", Build.VERSION.SDK_INT).put("buildDisplay", Build.DISPLAY)
                .put("mode", MODE_NAMES[mode]).put("scenario", scenario).put("listeningRoute", listeningRoute == null ? "Non specificato" : listeningRoute).put("sampleRate", RATE).put("channels", 1).put("state", "preparing")
                .put("audio", "audio.wav").put("events", events)
                .put("interpretation", "Le misure indicano energia e segnalazioni Android, non il numero di voci registrate. Verificare tramite ascolto.");
            SessionFiles.save(folder, metadata);
            int min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
            if (min <= 0) throw new IllegalStateException("Formato PCM 16 kHz mono non supportato: " + min);
            AudioFormat format = new AudioFormat.Builder().setSampleRate(RATE).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_IN_MONO).build();
            AudioRecord.Builder builder = new AudioRecord.Builder().setAudioFormat(format).setBufferSizeInBytes(Math.max(min * 2, RATE));
            if (mode == PLAYBACK) {
                AudioPlaybackCaptureConfiguration config = new AudioPlaybackCaptureConfiguration.Builder(projection)
                    .addMatchingUsage(AudioAttributes.USAGE_MEDIA).addMatchingUsage(AudioAttributes.USAGE_GAME).addMatchingUsage(AudioAttributes.USAGE_UNKNOWN).build();
                builder.setAudioPlaybackCaptureConfig(config);
            } else builder.setAudioSource(mode == RECOGNITION ? MediaRecorder.AudioSource.VOICE_RECOGNITION : MediaRecorder.AudioSource.MIC);
            AudioRecord local = builder.build(); recorder = local;
            if (local.getState() != AudioRecord.STATE_INITIALIZED) throw new IllegalStateException("AudioRecord non inizializzato");
            if (!running) throw new IllegalStateException("Prova annullata durante la preparazione");
            local.startRecording();
            if (local.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) throw new IllegalStateException("Android non ha avviato l’acquisizione");
            initialized = true; metadata.put("state", "recording");
            try (WavWriter wav = new WavWriter(new File(folder, "audio.wav"), RATE)) {
                short[] samples = new short[RATE / 10];
                while (running && SystemClock.elapsedRealtime() - origin < LIMIT_MS) {
                    int count = local.read(samples, 0, samples.length, AudioRecord.READ_BLOCKING);
                    if (!running) break;
                    if (count < 0) throw new IllegalStateException("Errore AudioRecord.read: " + count);
                    if (count == 0) { Thread.sleep(10); continue; }
                    wav.write(samples, count); stats.add(samples, count);
                    long now = SystemClock.elapsedRealtime();
                    if (now - lastCheckpoint >= 1000) {
                        int currentMode = audioManager.getMode();
                        if (currentMode != previousMode) { events.put(new JSONObject().put("elapsedMs", now - origin).put("audioMode", currentMode)); previousMode = currentMode; }
                        AudioRecordingConfiguration config = local.getActiveRecordingConfiguration();
                        if (config != null) {
                            boolean silenced = config.isClientSilenced(); configChecks++; if (silenced) silencedChecks++;
                            if (previousSilenced == null || previousSilenced != silenced) {
                                events.put(new JSONObject().put("elapsedMs", now - origin).put("clientSilenced", silenced)); previousSilenced = silenced;
                            }
                        }
                        wav.checkpoint(); updateStats(metadata, stats, now - origin, silencedChecks, configChecks);
                        SessionFiles.save(folder, metadata); lastCheckpoint = now;
                        String status = previousSilenced == Boolean.TRUE ? "Android segnala audio silenziato" : "Acquisizione · " + MODE_NAMES[mode];
                        snapshot = new Snapshot(true, status, (now - origin) / 1000, stats.rmsDb());
                    }
                }
                if (SystemClock.elapsedRealtime() - origin >= LIMIT_MS) stopReason = "Limite della prova: 2 minuti";
            }
        } catch (Exception error) { errorMessage = error.getClass().getSimpleName() + " · " + error.getMessage(); }
        finally {
            running = false;
            AudioRecord local = recorder; recorder = null;
            if (local != null) { try { local.stop(); } catch (Exception ignored) {} local.release(); }
            try {
                updateStats(metadata, stats, SystemClock.elapsedRealtime() - origin, silencedChecks, configChecks);
                metadata.put("state", errorMessage == null ? "complete" : "failed").put("finishedAtEpochMs", System.currentTimeMillis())
                    .put("stopReason", stopReason).put("initialized", initialized).put("error", errorMessage == null ? JSONObject.NULL : errorMessage);
                SessionFiles.save(folder, metadata);
            } catch (Exception saveError) { errorMessage = (errorMessage == null ? "" : errorMessage + "; ") + "Salvataggio metadati: " + saveError.getMessage(); }
            String message = errorMessage != null ? "Prova interrotta: " + errorMessage : silencedChecks > 0 ? "Prova salvata · Android ha segnalato silenziamento" : stats.rmsDb() < -70 ? "Prova salvata · segnale molto basso: riascolta" : "Prova salvata · riascolta per verificare le voci";
            completion = new Snapshot(false, message, stats.count() / RATE, stats.rmsDb());
            handler.post(() -> { if (destroyed) snapshot = completion; else stopSelf(); });
        }
    }
    private static void updateStats(JSONObject json, SignalStats stats, long wallMs, int silenced, int checks) throws JSONException {
        json.put("samples", stats.count()).put("audioDurationMs", stats.count() * 1000 / RATE).put("wallDurationMs", wallMs)
            .put("rmsDbfs", stats.rmsDb()).put("peakDbfs", stats.peakDb()).put("nonZeroSamples", stats.nonZero())
            .put("clippedSamples", stats.clipped()).put("silencedChecks", silenced).put("recordingConfigurationChecks", checks);
    }
    private void requestStop(String reason) {
        if (!running) return;
        stopReason = reason; running = false;
        snapshot = new Snapshot(true, "Salvataggio della prova…", snapshot.seconds, snapshot.rms);
        AudioRecord local = recorder;
        if (local != null) { try { local.stop(); } catch (Exception ignored) {} }
    }
    @Override public void onTaskRemoved(Intent rootIntent) { requestStop("App rimossa dalle attività recenti"); }
    @Override public void onDestroy() {
        destroyed = true; requestStop("Servizio terminato"); handler.removeCallbacks(timeout);
        if (projection != null) { projection.stop(); projection = null; }
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        stopForeground(STOP_FOREGROUND_REMOVE); if (completion != null) snapshot = completion; super.onDestroy();
    }
}
