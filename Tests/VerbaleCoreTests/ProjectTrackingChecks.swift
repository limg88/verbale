import Foundation
import VerbaleCore

private func trackingRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw VerbaleError.message(message) }
}
private func trackingReject(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw VerbaleError.message("Expected validation failure")
}
enum ProjectTrackingChecks {
    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ body: () throws -> Void) {
            do { try body(); print("PASS project tracking \(name)") }
            catch { failures += 1; print("FAIL project tracking \(name): \(error)") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-tracking-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var first = Meeting(title: "SAL uno", sources: [.system], destination: root, keepAudio: false)
        first.segments = [Segment(source: .system, start: 12, end: 16, text: "Laura invierà il piano entro venerdì.")]
        first.state = .complete
        let proposal = ActionProposal(meeting: first, text: "Inviare il piano", owner: "Laura", deadline: "venerdì", commitment: "agreed", references: ["S1"])
        var second = Meeting(title: "SAL due", sources: [.system], destination: root, keepAudio: false)
        second.segments = [Segment(source: .system, start: 30, end: 36, text: "Il piano slitta a martedì.")]
        second.state = .complete
        let update = ActionProposal(meeting: second, text: "Inviare il piano aggiornato", deadline: "martedì", references: ["S1"])
        check("two SAL persist one activity with both sources and original deadline") {
            var ledger = ProjectLedger()
            let project = try ledger.addProject(name: "Apollo")
            try ledger.assign(meetingID: first.id, to: project); try ledger.assign(meetingID: second.id, to: project)
            var fields = ActionFields(text: proposal.text, owner: "Laura", originalDeadline: "venerdì")
            let id = try ledger.confirm(proposal, fields: fields)
            fields.originalDeadline = "martedì"; fields.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
            try ledger.confirm(update, fields: fields, updating: id)
            let store = ProjectLedgerStore(file: root.appendingPathComponent("ledger.json"))
            try store.save(ledger)
            let saved = try store.load(), action = saved.actions[0]
            try trackingRequire(saved == ledger && saved.actions.count == 1 && action.id == id, "stable ID and full durable round trip")
            try trackingRequire(action.revisions.count == 2 && action.revisions[0].fields.originalDeadline == "venerdì" && action.fields.originalDeadline == "martedì", "history preserves prior deadline")
            try trackingRequire(action.sources.count == 2 && Set(action.sources.map(\.meetingID)) == Set([first.id, second.id]), "both meeting sources")
            try trackingRequire(action.sources[0].segmentID == first.segments[0].id && action.sources[1].quote == second.segments[0].text, "stable source IDs and snapshots")
            let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path)
            try trackingRequire((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private file permissions")
        }
        check("report regeneration and duplicate confirmation preserve PM edits") {
            var ledger = ProjectLedger(); let project = try ledger.addProject(name: "Apollo")
            try ledger.assign(meetingID: first.id, to: project)
            let fields = ActionFields(text: "Piano approvato dal PM", owner: "Responsabile confermato", status: .blocked)
            let id = try ledger.confirm(proposal, fields: fields)
            let regenerated = ActionProposal(meeting: first, text: "Inviare il piano", owner: "Altro nome", deadline: "domani", references: ["S1"])
            let before = ledger
            try trackingRequire(regenerated.id == proposal.id, "stable regeneration identity")
            try trackingReject { try ledger.confirm(regenerated, fields: ActionFields(text: regenerated.text)) }
            try trackingRequire(ledger == before && ledger.actions[0].id == id && ledger.actions[0].fields == fields, "manual values retained")
        }
        check("duplicate activity across meetings requires explicit update") {
            var ledger = ProjectLedger(); let project = try ledger.addProject(name: "Apollo")
            try ledger.assign(meetingID: first.id, to: project); try ledger.assign(meetingID: second.id, to: project)
            let fields = ActionFields(text: proposal.text)
            try ledger.confirm(proposal, fields: fields)
            try trackingReject { try ledger.confirm(update, fields: fields) }
            try trackingRequire(ledger.suggestedMatches(for: update).count == 1 && ledger.actions.count == 1, "suggestion without automatic duplicate")
        }
        check("project validation and assignments protect source consistency") {
            var ledger = ProjectLedger(); let p = try ledger.addProject(name: "Apollo"), q = try ledger.addProject(name: "Luna")
            try trackingReject { _ = try ledger.addProject(name: "  APOLLO  ") }
            try trackingReject { _ = try ledger.addProject(name: " ") }
            try trackingReject { try ledger.assign(meetingID: first.id, to: UUID()) }
            try trackingReject { try ledger.confirm(proposal, fields: ActionFields(text: "Piano")) }
            try ledger.assign(meetingID: first.id, to: p)
            let id = try ledger.confirm(proposal, fields: ActionFields(text: "Piano"))
            try trackingReject { try ledger.assign(meetingID: first.id, to: q) }
            try trackingReject { try ledger.assign(meetingID: first.id, to: nil) }
            try ledger.assign(meetingID: second.id, to: q)
            try trackingReject { try ledger.confirm(update, fields: ActionFields(text: "Piano"), updating: id) }
            try trackingRequire(ledger.suggestedMatches(for: update).isEmpty, "matching isolated to project")
        }
        check("due filters require a confirmed date and respect day boundaries") {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var ledger = ProjectLedger(); let project = try ledger.addProject(name: "Apollo")
            try ledger.assign(meetingID: first.id, to: project)
            var fields = ActionFields(text: "Piano", originalDeadline: "venerdì")
            let id = try ledger.confirm(proposal, fields: fields)
            try trackingRequire(!ledger.actions[0].isOverdue(at: now, calendar: calendar), "relative date is not guessed")
            fields.dueDate = calendar.startOfDay(for: now); try ledger.edit(id, fields: fields)
            try trackingRequire(!ledger.actions[0].isOverdue(at: now, calendar: calendar) && ledger.actions[0].isDueSoon(at: now, calendar: calendar), "today not overdue")
            fields.dueDate = calendar.date(byAdding: .day, value: -1, to: now); try ledger.edit(id, fields: fields)
            try trackingRequire(ledger.actions[0].isOverdue(at: now, calendar: calendar), "past date overdue")
            fields.status = .completed; try ledger.edit(id, fields: fields)
            try trackingRequire(!ledger.actions[0].isOverdue(at: now, calendar: calendar) && !ledger.actions[0].isDueSoon(at: now, calendar: calendar), "completed excluded")
        }
        check("manual edit retains provenance and no-op creates no revision") {
            var ledger = ProjectLedger(); let project = try ledger.addProject(name: "Apollo")
            try ledger.assign(meetingID: first.id, to: project)
            var fields = ActionFields(text: "Piano"); let id = try ledger.confirm(proposal, fields: fields)
            try ledger.edit(id, fields: fields)
            try trackingRequire(ledger.actions[0].revisions.count == 1, "no-op")
            fields.owner = "PM"; fields.status = .inProgress; try ledger.edit(id, fields: fields)
            try trackingRequire(ledger.actions[0].sources.count == 1 && ledger.actions[0].revisions.count == 2, "provenance survives edits")
            try trackingReject { try ledger.edit(id, fields: ActionFields(text: "   ")) }
        }
        check("legacy meetings decode and source IDs survive transcript reorder") {
            var object = try JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(first)) as! [String: Any]
            object.removeValue(forKey: "actionProposals")
            let old = try JSONCoding.decoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
            try trackingRequire(old.actionProposals == nil && old.id == first.id, "legacy compatibility")
            var changed = first; changed.segments.insert(Segment(source: .system, start: 0, end: 1, text: "Introduzione"), at: 0)
            try trackingRequire(proposal.sources[0].segmentID == changed.segments[1].id, "stable source does not resolve S1 again")
            let reindexed = ActionProposal(meeting: changed, text: proposal.text, references: ["S2"])
            try trackingRequire(reindexed.id == proposal.id && reindexed.sources[0].id == proposal.sources[0].id, "source identity survives reference renumbering")
            let invalid = ActionProposal(meeting: first, text: "Falsa attività", references: ["S0", "S99", "N", "M1"])
            var ledger = ProjectLedger(); let project = try ledger.addProject(name: "Apollo"); try ledger.assign(meetingID: first.id, to: project)
            try trackingReject { try ledger.confirm(invalid, fields: ActionFields(text: invalid.text)) }
        }
        check("corrupt ledger and failed writes preserve original bytes") {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("corrupt.json"), data = Data("not-json".utf8)
            try data.write(to: file)
            try trackingReject { _ = try ProjectLedgerStore(file: file).load() }
            try trackingRequire(try Data(contentsOf: file) == data, "corrupt file preserved")
            let blocked = root.appendingPathComponent("blocked"); try Data("existing".utf8).write(to: blocked)
            try trackingReject { try ProjectLedgerStore(file: blocked.appendingPathComponent("ledger.json")).save(ProjectLedger()) }
            try trackingRequire(try String(contentsOf: blocked) == "existing", "failed save preserves parent")
            let directoryTarget = root.appendingPathComponent("directory-target")
            try FileManager.default.createDirectory(at: directoryTarget, withIntermediateDirectories: false)
            let sentinel = directoryTarget.appendingPathComponent("original.txt")
            try Data("original".utf8).write(to: sentinel)
            try trackingReject { try ProjectLedgerStore(file: directoryTarget).save(ProjectLedger()) }
            try trackingRequire(try String(contentsOf: sentinel) == "original", "failed atomic commit preserves destination")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".project-ledger-") }
            try trackingRequire(leftovers.isEmpty, "temporary files cleaned after failure")
        }
        return failures
    }
}
