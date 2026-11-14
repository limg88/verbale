package io.verbale.probe;

import android.app.*;
import android.content.*;
import android.net.Uri;
import android.os.*;
import org.json.JSONObject;
import java.io.*;
import java.nio.*;
import java.nio.file.Files;
import java.util.*;

/** Run only on a dedicated emulator with host audio disabled. Tests the service, not actual calls. */
public final class ProbeInstrumentation extends Instrumentation {
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    private static void check(boolean condition, String label) { if (!condition) throw new AssertionError(label); }
    @Override public void onStart() {
        Bundle result = new Bundle(); Activity activity = null;
        try {
            Context context = getTargetContext();
            if (!Build.FINGERPRINT.contains("generic") && !Build.MODEL.contains("sdk_gphone")) throw new IllegalStateException("Test riservato all’emulatore");
            activity = startActivitySync(new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); waitForIdleSync();
            long before = System.currentTimeMillis();
            runOnMainSync(() -> context.startForegroundService(new Intent(context, CaptureService.class).setAction(CaptureService.START)
                .putExtra("mode", CaptureService.MIC).putExtra("scenario", "EMULATOR_ZERO_INPUT").putExtra("listeningRoute", "Emulatore senza audio host")));
            long deadline = SystemClock.elapsedRealtime() + 12000;
            while (SystemClock.elapsedRealtime() < deadline && CaptureService.snapshot.seconds < 2) Thread.sleep(100);
            check(CaptureService.snapshot.active && CaptureService.snapshot.seconds >= 2, "foreground PCM capture did not advance");
            runOnMainSync(() -> context.startService(new Intent(context, CaptureService.class).setAction(CaptureService.STOP)));
            deadline = SystemClock.elapsedRealtime() + 10000;
            while (CaptureService.snapshot.active && SystemClock.elapsedRealtime() < deadline) Thread.sleep(100);
            check(!CaptureService.snapshot.active, "service did not finalize");
            File folder = null; JSONObject meta = null;
            for (File candidate : SessionFiles.list(context)) {
                JSONObject data = SessionFiles.read(candidate);
                if (data.optLong("startedAtEpochMs") >= before && data.optString("scenario").equals("EMULATOR_ZERO_INPUT")) { folder = candidate; meta = data; break; }
            }
            check(meta != null && meta.optString("state").equals("complete"), "complete metadata missing");
            check(meta.optLong("samples") >= 16000, "not enough samples");
            byte[] wav = Files.readAllBytes(new File(folder, "audio.wav").toPath()); ByteBuffer bytes = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN);
            check(bytes.getInt(40) == wav.length - 44 && bytes.getInt(24) == 16000, "WAV header does not match payload");
            check(meta.optLong("samples") * 2 == wav.length - 44, "metadata and waveform disagree");
            Uri uri = new Uri.Builder().scheme("content").authority("io.verbale.probe.files").appendPath(folder.getName()).appendPath("session.json").build();
            try (InputStream stream = context.getContentResolver().openInputStream(uri)) { check(stream != null && stream.read() >= 0, "sharing provider read failed"); }
            boolean denied = false;
            try (ParcelFileDescriptor ignored = context.getContentResolver().openFileDescriptor(uri, "w")) { }
            catch (FileNotFoundException expected) { denied = true; }
            check(denied, "sharing provider accepted writes");
            result.putString("stream", "PASS foreground capture, stop/finalize, WAV/header/metadata agreement and read-only provider on emulator. No call compatibility claimed.\n");
            result.putString("probeResult", meta.toString());
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            result.putString("stream", "FAIL " + error + "\n"); finish(Activity.RESULT_CANCELED, result);
        } finally { if (activity != null) { Activity current = activity; runOnMainSync(current::finish); } }
    }
}
