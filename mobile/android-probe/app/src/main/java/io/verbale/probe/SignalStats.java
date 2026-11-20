package io.verbale.probe;

/** Measures PCM energy only. It never identifies speech or the number of speakers. */
public final class SignalStats {
    private long count, nonZero, clipped;
    private double squares;
    private int peak;
    public void add(short[] samples, int length) {
        if (length < 0 || length > samples.length) throw new IllegalArgumentException("length");
        for (int i = 0; i < length; i++) {
            int value = samples[i]; int magnitude = Math.abs(value);
            count++; if (value != 0) nonZero++; if (magnitude >= 32760) clipped++;
            peak = Math.max(peak, magnitude); squares += (double) value * value;
        }
    }
    public long count() { return count; }
    public long nonZero() { return nonZero; }
    public long clipped() { return clipped; }
    public double peakDb() { return db(peak / 32768.0); }
    public double rmsDb() { return db(count == 0 ? 0 : Math.sqrt(squares / count) / 32768.0); }
    private static double db(double value) { return value > 0 ? Math.max(-120, 20 * Math.log10(value)) : -120; }
}
