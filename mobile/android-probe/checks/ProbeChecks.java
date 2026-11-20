package io.verbale.probe;
import java.io.*;
import java.nio.*;
import java.nio.file.*;
import java.util.*;

public final class ProbeChecks {
    private static void check(boolean condition, String name) { if (!condition) throw new AssertionError(name); System.out.println("PASS " + name); }
    private static void denied(File root, List<String> parts) throws Exception {
        try { SharePaths.resolve(root, parts); throw new AssertionError("path accepted: " + parts); }
        catch (IOException expected) { System.out.println("PASS rejected " + parts); }
    }
    public static void main(String[] args) throws Exception {
        Path work = Files.createTempDirectory("verbale-probe-checks");
        try {
            SignalStats silence = new SignalStats(); silence.add(new short[16000], 16000);
            check(silence.count() == 16000 && silence.nonZero() == 0 && silence.rmsDb() == -120, "silence is finite and not mistaken for signal");
            SignalStats full = new SignalStats(); full.add(new short[]{32767, -32768}, 2);
            check(full.clipped() == 2 && full.peakDb() == 0 && full.rmsDb() > -0.01, "PCM extrema, clipping and RMS");
            SignalStats split = new SignalStats(); split.add(new short[]{100, -100}, 2); split.add(new short[]{0, 100}, 2);
            check(split.count() == 4 && split.nonZero() == 3 && split.rmsDb() < -50 && split.rmsDb() > -53, "accumulated energy across blocks");
            File wav = work.resolve("audio.wav").toFile();
            try (WavWriter writer = new WavWriter(wav, 16000)) {
                writer.write(new short[]{1, -2, 32767, -32768}, 4); writer.checkpoint();
                ByteBuffer header = ByteBuffer.wrap(Files.readAllBytes(wav.toPath())).order(ByteOrder.LITTLE_ENDIAN);
                check(header.getInt(40) == 8 && header.getInt(24) == 16000 && header.getShort(22) == 1, "checkpoint creates valid mono PCM header");
                writer.write(new short[]{42}, 1);
            }
            byte[] data = Files.readAllBytes(wav.toPath()); ByteBuffer b = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN);
            check(data.length == 54 && b.getInt(4) == 46 && b.getInt(40) == 10 && b.getShort(46) == -2 && b.getShort(52) == 42, "final WAV length and sample bytes match");
            try { new WavWriter(wav, 16000); throw new AssertionError("overwritten"); } catch (IOException expected) { check(Files.readAllBytes(wav.toPath()).length == 54, "existing recording never overwritten"); }
            File root = work.resolve("probes").toFile(); check(root.mkdir(), "private archive created");
            String id = UUID.randomUUID().toString(); File session = new File(root, id); check(session.mkdir(), "session folder created");
            Files.write(new File(session, "session.json").toPath(), new byte[]{123, 125});
            check(SharePaths.resolve(root, List.of(id, "session.json")).isFile(), "explicit metadata can be shared");
            denied(root, List.of("..", "session.json")); denied(root, List.of(id, "../audio.wav")); denied(root, List.of(id, "secret.txt")); denied(root, List.of(id, "session.json", "extra"));
            String linkId = UUID.randomUUID().toString(); Files.createSymbolicLink(new File(root, linkId).toPath(), work);
            Files.write(work.resolve("session.json"), new byte[]{123, 125}); denied(root, List.of(linkId, "session.json"));
            System.out.println("All probe checks passed; no audio device or network used.");
        } finally {
            try (var paths = Files.walk(work)) { for (Path p : paths.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(p); }
        }
    }
}
