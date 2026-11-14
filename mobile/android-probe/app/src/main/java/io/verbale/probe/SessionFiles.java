package io.verbale.probe;

import android.content.Context;
import android.util.AtomicFile;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;

final class SessionFiles {
    static File root(Context context) {
        File root = new File(context.getFilesDir(), "probes");
        if (!root.isDirectory() && !root.mkdirs()) throw new IllegalStateException("Archivio non disponibile");
        return root;
    }
    static synchronized void save(File folder, JSONObject json) throws Exception {
        AtomicFile file = new AtomicFile(new File(folder, "session.json")); FileOutputStream stream = null;
        try {
            stream = file.startWrite(); stream.write(json.toString(2).getBytes(StandardCharsets.UTF_8)); file.finishWrite(stream);
        } catch (Exception error) { file.failWrite(stream); throw error; }
    }
    static synchronized JSONObject read(File folder) throws Exception {
        byte[] bytes = new AtomicFile(new File(folder, "session.json")).readFully();
        return new JSONObject(new String(bytes, StandardCharsets.UTF_8));
    }
    static List<File> list(Context context) {
        File[] folders = root(context).listFiles(File::isDirectory);
        if (folders == null) return new ArrayList<>();
        Arrays.sort(folders, Comparator.comparingLong(File::lastModified).reversed());
        return Arrays.asList(folders);
    }
}
