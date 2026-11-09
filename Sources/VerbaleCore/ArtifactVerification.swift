import Foundation
import Darwin

/// Immutable audio is hashed once per unchanged source/destination pair, rather than
/// rereading the entire recording on every live export. ctime catches edits even if
/// a tool restores mtime; inode/device catch replacement at the same path.
final class ArtifactVerification {
    private struct Signature: Equatable {
        let device: Int32, inode: UInt64, bytes: Int64
        let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
        init(_ url:URL) throws {
            var value = stat()
            guard fstatat(AT_FDCWD,url.path,&value,0) == 0 else { throw CocoaError(.fileReadUnknown) }
            device = value.st_dev; inode = value.st_ino; bytes = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
        }
    }
    private struct Pair: Equatable { let source:Signature, output:Signature }
    private var verified:[String:Pair] = [:]
    func verify(_ source:URL,_ output:URL) throws {
        let key = source.path+"\0"+output.path
        let before = try Pair(source:Signature(source),output:Signature(output))
        if verified[key] == before { return }
        let equal = try ModelManager.digest(source) == ModelManager.digest(output)
        let after = try Pair(source:Signature(source),output:Signature(output))
        guard equal,before == after else {
            verified.removeValue(forKey:key)
            throw VerbaleError.message("Allegato preesistente diverso o modificato durante la verifica: \(output.lastPathComponent). Scegli una nuova cartella.")
        }
        if verified.count >= 8192 { verified.removeAll(keepingCapacity:true) }
        verified[key] = before
    }
}
