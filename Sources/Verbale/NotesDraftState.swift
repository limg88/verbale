import Foundation
import Combine

/// Keystrokes notify only the notes editor. Drafts survive navigation and failed saves.
@MainActor final class NotesDraftState: ObservableObject {
    @Published private(set) var values:[UUID:String] = [:]
    @Published private(set) var failures:Set<UUID> = []
    private var pending:Set<UUID> = []
    private var tasks:[UUID:Task<Void,Never>] = [:]
    var submit:((UUID,String)->Void)?
    func text(for id:UUID,fallback:String)->String { values[id] ?? fallback }
    func contains(_ id:UUID)->Bool { values[id] != nil }
    func edit(_ text:String,id:UUID) {
        values[id]=text;failures.remove(id);pending.insert(id)
        tasks[id]?.cancel()
        tasks[id]=Task { [weak self] in
            do {try await Task.sleep(for:.milliseconds(500))} catch {return}
            self?.commit(id)
        }
    }
    func commit(_ id:UUID) {
        tasks.removeValue(forKey:id)?.cancel()
        guard let text=values[id] else{return}
        pending.remove(id);submit?(id,text)
    }
    func flush() { for id in Array(values.keys) {commit(id)} }
    func saved(_ id:UUID,text:String) {
        guard values[id]==text,!pending.contains(id) else{return}
        values.removeValue(forKey:id);failures.remove(id)
    }
    func failed(_ id:UUID) {if values[id] != nil {failures.insert(id)}}
}
