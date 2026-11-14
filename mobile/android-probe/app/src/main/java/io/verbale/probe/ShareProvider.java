package io.verbale.probe;

import android.content.*;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.*;
import java.util.List;

/** Read-only, per-URI sharing. Only audio.wav and session.json in UUID session folders are exposed. */
public final class ShareProvider extends ContentProvider {
    private File file(Uri uri) throws IOException {
        if (!"io.verbale.probe.files".equals(uri.getAuthority())) throw new FileNotFoundException("Autorità non valida");
        return SharePaths.resolve(SessionFiles.root(getContext()), uri.getPathSegments());
    }
    @Override public boolean onCreate() { return true; }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new FileNotFoundException("Sola lettura");
        try { return ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY); }
        catch (IOException error) { throw new FileNotFoundException(error.getMessage()); }
    }
    @Override public String getType(Uri uri) { return uri.getLastPathSegment() != null && uri.getLastPathSegment().endsWith(".wav") ? "audio/wav" : "application/json"; }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) {
        try {
            File file = file(uri); String[] columns = projection == null ? new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE} : projection;
            MatrixCursor cursor = new MatrixCursor(columns); Object[] row = new Object[columns.length];
            for (int i = 0; i < columns.length; i++) {
                if (OpenableColumns.DISPLAY_NAME.equals(columns[i])) row[i] = file.getName();
                else if (OpenableColumns.SIZE.equals(columns[i])) row[i] = file.length();
            }
            cursor.addRow(row); return cursor;
        } catch (IOException error) { throw new IllegalArgumentException(error); }
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException("Sola lettura"); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException("Sola lettura"); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException("Sola lettura"); }
}
