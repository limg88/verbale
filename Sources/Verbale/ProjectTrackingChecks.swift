import AppKit
import SwiftUI
import VerbaleCore

extension AppModel {
    /// Preview only: two SAL through the real durable ledger and real SwiftUI views.
    func checkProjectTrackingUI(window: NSWindow, root: URL, checks: inout [String: Bool]) async throws {
        let folder = root.appendingPathComponent("ProjectChecks-" + UUID().uuidString)
        let tracker = ProjectTracker(file: folder.appendingPathComponent("project-ledger.json"))
        let previousView = window.contentView
        let previousMeeting = current, previousTab = tab
        defer { window.contentView = previousView; current = previousMeeting; tab = previousTab }
        var first = Meeting(title: "SAL · Piano di rilascio", sources: [.system], destination: folder, keepAudio: false)
        first.state = .complete; first.report = "Report sintetico"; first.reportStatus = "Completato"
        first.segments = [Segment(source: .system, start: 12, end: 16, text: "Laura invierà il piano entro venerdì.")]
        let proposal = ActionProposal(meeting: first, text: "Inviare il piano di rilascio", owner: "Laura", deadline: "venerdì", commitment: "agreed", references: ["S1"])
        first.actionProposals = [proposal]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try store.save(first); meetings.append(first); current = first
        var second = Meeting(title: "SAL · Aggiornamento del piano", sources: [.system], destination: folder, keepAudio: false)
        second.state = .complete; second.segments = [Segment(source: .system, start: 30, end: 35, text: "Il piano slitta a martedì, attendiamo il collaudo.")]
        let update = ActionProposal(meeting: second, text: "Inviare il piano di rilascio aggiornato", deadline: "martedì", declaredStatus: "Bloccata dal collaudo", references: ["S1"])
        second.actionProposals = [update]; second.reportStatus = "Completato"; second.report = "Report sintetico"
        try store.save(second); meetings.append(second)
        checks["projects create and assign two SAL"] = tracker.change { ledger in
            let id = try ledger.addProject(name: "Apollo · Rilascio")
            try ledger.assign(meetingID: first.id, to: id); try ledger.assign(meetingID: second.id, to: id)
        }
        func capture<V: View>(_ view: V, name: String) async throws {
            window.contentView = NSHostingView(rootView: view.environmentObject(self))
            window.setContentSize(NSSize(width: 1000, height: 720))
            try await Task.sleep(for: .milliseconds(250))
            guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw VerbaleError.message("Preview non disponibile") }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw VerbaleError.message("PNG non disponibile") }
            try data.write(to: root.appendingPathComponent(name + ".png"))
        }
        try await capture(MeetingActionsView(tracker: tracker, meeting: first).padding(24), name: "projects-proposals")
        try await capture(ActionEditor(tracker: tracker, proposal: proposal), name: "projects-review")
        checks["projects confirm first SAL proposal"] = tracker.change { ledger in
            try ledger.confirm(proposal, fields: ActionFields(text: proposal.text, owner: "Laura", originalDeadline: "venerdì"))
        }
        let id = tracker.ledger.actions[0].id
        checks["projects suggest existing activity in next SAL"] = tracker.ledger.suggestedMatches(for: update).first?.id == id
        checks["projects update same task after second SAL"] = tracker.change { ledger in
            var fields = ledger.actions[0].fields
            fields.originalDeadline = "martedì"; fields.dueDate = Calendar.current.date(byAdding: .day, value: -1, to: Date()); fields.status = .blocked; fields.dependencies = "Completare il collaudo"
            try ledger.confirm(update, fields: fields, updating: id)
        }
        let restored = ProjectTracker(file: folder.appendingPathComponent("project-ledger.json"))
        checks["projects restart retains one task two sources and history"] = restored.ledger.actions.count == 1 && restored.ledger.actions[0].sources.count == 2 && restored.ledger.actions[0].revisions.count == 2 && restored.ledger.actions[0].revisions[0].fields.originalDeadline == "venerdì"
        try await capture(ProjectFollowUpView(tracker: tracker), name: "projects-followup")
        try await capture(ActionEditor(tracker: tracker, action: tracker.ledger.actions[0]), name: "projects-history")
        let before = tracker.ledger
        let stable = try Data(contentsOf: folder.appendingPathComponent("project-ledger.json"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("project-ledger.json"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("project-ledger.json"), withIntermediateDirectories: false)
        let failed = tracker.change { ledger in var fields = ledger.actions[0].fields; fields.owner = "Modifica non salvata"; try ledger.edit(id, fields: fields) }
        checks["projects failed save retains published ledger and visible error"] = !failed && tracker.ledger == before && tracker.error != nil
        try FileManager.default.removeItem(at: folder.appendingPathComponent("project-ledger.json")); try stable.write(to: folder.appendingPathComponent("project-ledger.json"), options: .atomic)
        tracker.reload()
        checks["projects retry loads original durable values"] = tracker.available && tracker.ledger == before
        try Data("corrupt".utf8).write(to: folder.appendingPathComponent("project-ledger.json"), options: .atomic)
        let corrupt = ProjectTracker(file: folder.appendingPathComponent("project-ledger.json"))
        let corruptBytes = try String(contentsOf: folder.appendingPathComponent("project-ledger.json"))
        checks["projects corrupt file disables edits and preserves bytes"] = !corrupt.available && !corrupt.change { _ in } && corruptBytes == "corrupt"
    }
}
