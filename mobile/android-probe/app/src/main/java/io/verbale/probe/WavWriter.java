package io.verbale.probe;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;

/** Single worker owns the stream. Checkpoint headers preserve a playable prefix after interruption. */
public final class WavWriter implements AutoCloseable {
    private final RandomAccessFile file;
    private final int sampleRate;
    private long bytes;
    public WavWriter(File path, int sampleRate) throws IOException {
        if (path.exists()) throw new IOException("File audio già presente");
        this.sampleRate = sampleRate; file = new RandomAccessFile(path, "rw"); checkpoint();
    }
    public void write(short[] values, int length) throws IOException {
        byte[] out = new byte[length * 2];
        for (int i = 0; i < length; i++) { out[i * 2] = (byte) values[i]; out[i * 2 + 1] = (byte) (values[i] >> 8); }
        file.seek(44 + bytes); file.write(out); bytes += out.length;
    }
    private void le16(int value) throws IOException { file.write(value & 255); file.write((value >> 8) & 255); }
    private void le32(long value) throws IOException { le16((int) value); le16((int) (value >> 16)); }
    public void checkpoint() throws IOException {
        file.seek(0); file.writeBytes("RIFF"); le32(36 + bytes); file.writeBytes("WAVEfmt "); le32(16);
        le16(1); le16(1); le32(sampleRate); le32(sampleRate * 2L); le16(2); le16(16);
        file.writeBytes("data"); le32(bytes); file.getFD().sync(); file.seek(44 + bytes);
    }
    @Override public void close() throws IOException { try { checkpoint(); } finally { file.close(); } }
}
