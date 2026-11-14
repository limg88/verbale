package io.verbale.probe;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.media.*;
import android.media.projection.MediaProjectionManager;
import android.net.Uri;
import android.os.*;
import android.view.*;
import android.widget.*;
import org.json.JSONObject;
import java.io.File;
import java.text.DateFormat;
import java.util.*;

public final class MainActivity extends Activity {
    private static final int INK = Color.rgb(34, 35, 51), PURPLE = Color.rgb(91, 77, 207);
    private final Handler handler = new Handler(Looper.getMainLooper());
    private TextView state, level;
    private Spinner mode, scenario, route;
    private Button start, stop;
    private LinearLayout results;
    private MediaPlayer player;
    private String listState = "";
    private final Runnable ticker = new Runnable() { public void run() { refresh(); handler.postDelayed(this, 500); } };

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        ScrollView scroll = new ScrollView(this); scroll.setBackgroundColor(Color.rgb(245, 245, 251));
        LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL); root.setPadding(dp(22), dp(22), dp(22), dp(30));
        scroll.addView(root); setContentView(scroll);
        scroll.setOnApplyWindowInsetsListener((view, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) { android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout()); view.setPadding(bars.left, bars.top, bars.right, bars.bottom); }
            else view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(), insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        root.addView(text("VERBALE / PROVA AUDIO", 13, PURPLE));
        root.addView(text("Prima ascoltiamo cosa arriva.", 27, INK));
        root.addView(text(Build.MANUFACTURER + " " + Build.MODEL + " · Android " + Build.VERSION.RELEASE + " · API " + Build.VERSION.SDK_INT, 13, INK));
        root.addView(text("APK diagnostico: non è ancora il registratore chiamate definitivo. Nessun invio automatico, nessuna trascrizione. Ogni prova dura al massimo 2 minuti.", 15, INK));
        Button help = button("Come eseguire le prove", false); help.setOnClickListener(v -> help()); root.addView(help);
        LinearLayout panel = card(); root.addView(panel);
        state = text("Pronto per una prova", 18, INK); panel.addView(state);
        level = text("Nessuna acquisizione attiva", 13, INK); panel.addView(level);
        panel.addView(text("Quale audio proviamo?", 14, INK)); mode = spinner(CaptureService.MODE_NAMES); panel.addView(mode);
        panel.addView(text("Tipo di prova (etichetta manuale)", 14, INK));
        scenario = spinner(new String[]{"Voce di controllo, senza chiamata", "Telefonata", "WhatsApp", "Teams"}); panel.addView(scenario);
        panel.addView(text("Come ascolti la chiamata?", 14, INK));
        route = spinner(new String[]{"Vivavoce", "Telefono all’orecchio", "Auricolari Bluetooth", "Cuffie con cavo", "Non specificato"}); panel.addView(route);
        panel.addView(text("Audio interno prova solo i flussi che Android rende catturabili. Le chiamate VoIP normalmente sono escluse; il registratore può ricevere silenzio. Un livello audio positivo non dimostra la presenza di entrambe le voci.", 13, INK));
        start = button("Avvia prova", true); start.setOnClickListener(v -> begin()); panel.addView(start);
        stop = button("Termina e salva", false); stop.setOnClickListener(v -> startService(new Intent(this, CaptureService.class).setAction(CaptureService.STOP))); panel.addView(stop);
        root.addView(text("Prove salvate", 22, INK));
        root.addView(text("Riascolta dopo la chiamata e annota se senti la tua voce e quella dell’interlocutore. Condividi audio e diagnostica soltanto se lo desideri.", 14, INK));
        results = new LinearLayout(this); results.setOrientation(LinearLayout.VERTICAL); root.addView(results);
        if (saved != null) { mode.setSelection(saved.getInt("mode")); scenario.setSelection(saved.getInt("scenario")); route.setSelection(saved.getInt("route")); }
    }
    @Override public void onSaveInstanceState(Bundle out) { out.putInt("mode", mode.getSelectedItemPosition()); out.putInt("scenario", scenario.getSelectedItemPosition()); out.putInt("route", route.getSelectedItemPosition()); super.onSaveInstanceState(out); }
    @Override public void onResume() { super.onResume(); listState = ""; handler.post(ticker); }
    @Override public void onPause() { handler.removeCallbacks(ticker); releasePlayer(); super.onPause(); }
    private void begin() {
        if (CaptureService.snapshot.active) return;
        releasePlayer();
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            ArrayList<String> permissions = new ArrayList<>(); permissions.add(Manifest.permission.RECORD_AUDIO);
            if (Build.VERSION.SDK_INT >= 33) permissions.add(Manifest.permission.POST_NOTIFICATIONS);
            requestPermissions(permissions.toArray(new String[0]), 10); return;
        }
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 11); return;
        }
        launchMode();
    }
    @Override public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(code, permissions, results);
        if (code == 10 || code == 11) {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) launchMode();
            else toast("La prova richiede il permesso microfono. Puoi abilitarlo dalle impostazioni dell’app.");
        }
    }
    private void launchMode() {
        if (mode.getSelectedItemPosition() == CaptureService.PLAYBACK) {
            startActivityForResult(getSystemService(MediaProjectionManager.class).createScreenCaptureIntent(), 20);
        } else launch(null, 0);
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == 20 && result == RESULT_OK && data != null) launch(data, result);
        else if (request == 20) toast("Prova audio interno annullata");
    }
    private void launch(Intent data, int code) {
        try {
            int selectedMode = data != null ? CaptureService.PLAYBACK : mode.getSelectedItemPosition();
            Intent intent = new Intent(this, CaptureService.class).setAction(CaptureService.START).putExtra("mode", selectedMode)
                .putExtra("scenario", scenario.getSelectedItem().toString()).putExtra("listeningRoute", route.getSelectedItem().toString());
            if (data != null) intent.putExtra("projectionData", data).putExtra("resultCode", code);
            CaptureService.snapshot = new CaptureService.Snapshot(true, "Richiesta di avvio…", 0, -120);
            startForegroundService(intent); refresh();
        } catch (Exception error) { CaptureService.snapshot = new CaptureService.Snapshot(false, "Avvio rifiutato: " + error.getMessage(), 0, -120); refresh(); }
    }
    private void refresh() {
        CaptureService.Snapshot snapshot = CaptureService.snapshot;
        state.setText(snapshot.message);
        int audioMode = getSystemService(AudioManager.class).getMode();
        level.setText(String.format(Locale.ITALY, "%d s · RMS %.1f dBFS\nStato audio Android: %s (%d)", snapshot.seconds, snapshot.rms, audioMode == AudioManager.MODE_IN_CALL ? "telefonata" : audioMode == AudioManager.MODE_IN_COMMUNICATION ? "comunicazione" : "altro", audioMode));
        start.setEnabled(!snapshot.active); stop.setEnabled(snapshot.active);
        mode.setEnabled(!snapshot.active); scenario.setEnabled(!snapshot.active); route.setEnabled(!snapshot.active);
        String key = snapshot.active + "|" + snapshot.message;
        if (!key.equals(listState)) { listState = key; reloadResults(); }
    }
    private void reloadResults() {
        results.removeAllViews(); List<File> folders = SessionFiles.list(this);
        if (folders.isEmpty()) { results.addView(text("Le prove compariranno qui dopo l’arresto.", 14, INK)); return; }
        int shown = 0;
        for (File folder : folders) {
            if (shown++ >= 20) break;
            try {
                JSONObject info = SessionFiles.read(folder); LinearLayout card = card(); results.addView(card);
                String date = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(new Date(info.optLong("startedAtEpochMs")));
                card.addView(text(info.optString("scenario") + " · " + date, 17, INK));
                card.addView(text(info.optString("mode") + "\n" + info.optString("listeningRoute", "Ascolto non specificato"), 13, INK));
                String status = info.optString("state");
                if ((status.equals("recording") || status.equals("preparing")) && !CaptureService.snapshot.active) status = "interrotta: parte finale non verificata";
                card.addView(text(String.format(Locale.ITALY, "%s · %.1f s audio · RMS %.1f dBFS\nSegnalazioni di silenziamento Android: %d su %d verifiche", status, info.optLong("audioDurationMs") / 1000.0, info.optDouble("rmsDbfs", -120), info.optInt("silencedChecks"), info.optInt("recordingConfigurationChecks")), 13, INK));
                if (!info.isNull("error")) card.addView(text(info.optString("error"), 13, Color.rgb(160, 40, 40)));
                if (info.has("manualLocalVoice")) card.addView(text("Ascolto manuale · mia voce: " + answer(info, "manualLocalVoice") + "; interlocutore: " + answer(info, "manualRemoteVoice"), 13, PURPLE));
                Button play = button("Ascolta / interrompi", false); play.setEnabled(!CaptureService.snapshot.active && new File(folder, "audio.wav").length() > 44); play.setOnClickListener(v -> play(folder)); card.addView(play);
                Button review = button("Annota quali voci senti", false); review.setEnabled(!CaptureService.snapshot.active); review.setOnClickListener(v -> review(folder)); card.addView(review);
                Button share = button("Condividi audio e diagnostica…", false); share.setEnabled(!CaptureService.snapshot.active); share.setOnClickListener(v -> share(folder)); card.addView(share);
                Button details = button("Dettagli della prova", false); details.setOnClickListener(v -> details(folder)); card.addView(details);
            } catch (Exception error) { results.addView(text("Prova incompleta · " + folder.getName() + "\n" + error.getMessage(), 13, INK)); }
        }
    }
    private void play(File folder) {
        if (player != null) { releasePlayer(); return; }
        try {
            player = new MediaPlayer(); player.setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build());
            player.setDataSource(new File(folder, "audio.wav").getPath()); player.setOnCompletionListener(p -> releasePlayer());
            player.setOnErrorListener((p, what, extra) -> { releasePlayer(); toast("Audio non riproducibile: " + what); return true; });
            player.prepare(); player.start();
        } catch (Exception error) { releasePlayer(); toast(error.getMessage()); }
    }
    private void releasePlayer() { if (player != null) { player.release(); player = null; } }
    private void review(File folder) {
        try {
            JSONObject info = SessionFiles.read(folder); LinearLayout form = new LinearLayout(this); form.setOrientation(LinearLayout.VERTICAL); form.setPadding(dp(20), dp(12), dp(20), dp(12));
            form.addView(text("Dopo aver riascoltato: senti la tua voce?", 15, INK)); Spinner local = spinner(new String[]{"Non verificato", "Sì", "No"}); local.setSelection(selection(info, "manualLocalVoice")); form.addView(local);
            form.addView(text("Senti la voce dell’interlocutore?", 15, INK)); Spinner remote = spinner(new String[]{"Non verificato", "Sì", "No"}); remote.setSelection(selection(info, "manualRemoteVoice")); form.addView(remote);
            new AlertDialog.Builder(this).setTitle("Esito dell’ascolto").setView(form).setNegativeButton("Annulla", null).setPositiveButton("Salva", (d, which) -> {
                try {
                    JSONObject latest = SessionFiles.read(folder);
                    latest.put("manualLocalVoice", local.getSelectedItemPosition() == 0 ? JSONObject.NULL : local.getSelectedItemPosition() == 1);
                    latest.put("manualRemoteVoice", remote.getSelectedItemPosition() == 0 ? JSONObject.NULL : remote.getSelectedItemPosition() == 1);
                    latest.put("manualReviewAtEpochMs", System.currentTimeMillis()); SessionFiles.save(folder, latest); reloadResults();
                } catch (Exception error) { toast(error.getMessage()); }
            }).show();
        } catch (Exception error) { toast(error.getMessage()); }
    }
    private int selection(JSONObject info, String key) { return info.isNull(key) ? 0 : info.optBoolean(key) ? 1 : 2; }
    private String answer(JSONObject info, String key) { return info.isNull(key) ? "non verificato" : info.optBoolean(key) ? "sì" : "no"; }
    private void share(File folder) {
        ArrayList<Uri> uris = new ArrayList<>();
        for (String name : new String[]{"audio.wav", "session.json"}) if (new File(folder, name).isFile()) uris.add(new Uri.Builder().scheme("content").authority("io.verbale.probe.files").appendPath(folder.getName()).appendPath(name).build());
        if (uris.isEmpty()) return;
        Intent share = new Intent(Intent.ACTION_SEND_MULTIPLE).setType("*/*").putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        ClipData clip = ClipData.newUri(getContentResolver(), "Prova Verbale", uris.get(0)); for (int i = 1; i < uris.size(); i++) clip.addItem(new ClipData.Item(uris.get(i))); share.setClipData(clip);
        startActivity(Intent.createChooser(share, "Condividi la prova selezionata"));
    }
    private void details(File folder) {
        try { TextView text = text(SessionFiles.read(folder).toString(2), 12, INK); text.setTextIsSelectable(true); ScrollView scroll = new ScrollView(this); scroll.addView(text); new AlertDialog.Builder(this).setTitle("Diagnostica locale").setView(scroll).setPositiveButton("Chiudi", null).show(); }
        catch (Exception error) { toast(error.getMessage()); }
    }
    private void help() {
        new AlertDialog.Builder(this).setTitle("Prove sul tuo Galaxy S25").setMessage("1. Senza chiamate, scegli Microfono · MIC, registra una frase e riascolta: è il controllo di base.\n\n2. Scegli Telefonata, WhatsApp o Teams e il modo di ascolto. Avvia la prova e passa alla chiamata. Se la chiamata è già attiva, Android potrebbe rifiutare o silenziare l’acquisizione.\n\n3. Dopo la chiamata torna qui, termina e riascolta. Annota quali voci senti.\n\n4. Puoi ripetere con VOICE_RECOGNITION e Audio interno. Per quest’ultimo Android chiede una nuova autorizzazione di condivisione: l’app salva solo audio. I flussi vocali non sono normalmente catturabili.\n\nNon modificare il volume o le impostazioni audio mentre confronti le prove. La prova termina automaticamente dopo 2 minuti. Non invia file a servizi esterni; la condivisione è un’azione manuale.")
            .setPositiveButton("Ho capito", null).show();
    }
    private Spinner spinner(String[] values) { Spinner s = new Spinner(this); ArrayAdapter<String> a = new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, values); s.setAdapter(a); s.setMinimumHeight(dp(52)); return s; }
    private TextView text(String value, int size, int color) { TextView t = new TextView(this); t.setText(value); t.setTextSize(size); t.setTextColor(color); t.setPadding(0, dp(7), 0, dp(7)); t.setLineSpacing(dp(3), 1); return t; }
    private Button button(String title, boolean primary) { Button b = new Button(this); b.setText(title); b.setAllCaps(false); b.setMinHeight(dp(50)); if (primary) { b.setBackgroundTintList(android.content.res.ColorStateList.valueOf(PURPLE)); b.setTextColor(Color.WHITE); } return b; }
    private LinearLayout card() { LinearLayout c = new LinearLayout(this); c.setOrientation(LinearLayout.VERTICAL); c.setPadding(dp(16), dp(12), dp(16), dp(16)); c.setBackgroundColor(Color.WHITE); LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(-1, -2); p.setMargins(0, dp(14), 0, dp(10)); c.setLayoutParams(p); return c; }
    private int dp(int value) { return Math.round(getResources().getDisplayMetrics().density * value); }
    private void toast(String message) { Toast.makeText(this, message, Toast.LENGTH_LONG).show(); }
}
