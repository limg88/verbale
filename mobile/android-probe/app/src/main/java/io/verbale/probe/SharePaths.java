package io.verbale.probe;

import java.io.*;
import java.util.List;

final class SharePaths {
    static File resolve(File root, List<String> parts) throws IOException {
        if (parts.size() != 2 || !parts.get(0).matches("[a-fA-F0-9-]{36}") ||
            !(parts.get(1).equals("audio.wav") || parts.get(1).equals("session.json"))) throw new FileNotFoundException("Percorso non valido");
        File file = new File(new File(root, parts.get(0)), parts.get(1)).getCanonicalFile();
        if (!file.getPath().startsWith(root.getCanonicalPath() + File.separator) || !file.isFile()) throw new FileNotFoundException("File non disponibile");
        return file;
    }
}
