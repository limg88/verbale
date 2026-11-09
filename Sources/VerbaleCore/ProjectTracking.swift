import Foundation
import CryptoKit
import Darwin

public struct ActionSource: Codable, Identifiable, Equatable, Sendable {
    public var id: String { meetingID.uuidString + ":" + (segmentID?.uuidString ?? reference) }
    public let meetingID: UUID
    public let meetingTitle: String
    public let meetingDate: Date
    public let reference: String
    public let segmentID: UUID?
    public let timestamp: Double?
    public let quote: String
}

public struct ActionProposal: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let meetingID: UUID
    public let text: String
    public let owner: String?
    public let deadline: String?
    public let declaredStatus: String?
    public let dependencies: String?
    public let commitment: String
    public let sources: [ActionSource]

    public init(meeting: Meeting, text: String, owner: String? = nil, deadline: String? = nil,
                declaredStatus: String? = nil, dependencies: String? = nil,
                commitment: String = "unclear", references: [String]) {
        self.meetingID = meeting.id; self.text = text; self.owner = owner; self.deadline = deadline
        self.declaredStatus = declaredStatus; self.dependencies = dependencies; self.commitment = commitment
        let segments = meeting.segments.sorted { $0.start < $1.start }
        let resolvedSources: [ActionSource] = references.compactMap { ref in
            guard ref.hasPrefix("S"), let number = Int(ref.dropFirst()), number > 0, number <= segments.count else { return nil }
            let segment = segments[number - 1]
            return ActionSource(meetingID: meeting.id, meetingTitle: meeting.title, meetingDate: meeting.started,
                                reference: ref, segmentID: segment.id, timestamp: segment.start, quote: segment.text)
        }
        sources = resolvedSources
        let identity = meeting.id.uuidString + "\n" + Self.normalized(text) + "\n" + resolvedSources.compactMap { $0.segmentID?.uuidString }.sorted().joined(separator: ",")
        id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "it_IT"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public struct TrackedProject: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public init(name: String) { self.name = name }
}
public enum ActionStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case open, inProgress, blocked, completed
    public var id: String { rawValue }
    public var label: String {
        switch self { case .open: return "Aperta"; case .inProgress: return "In corso"; case .blocked: return "Bloccata"; case .completed: return "Completata" }
    }
}
public struct ActionFields: Codable, Equatable, Sendable {
    public var text: String
    public var owner: String
    public var originalDeadline: String
    public var dueDate: Date?
    public var status: ActionStatus
    public var dependencies: String
    public init(text: String, owner: String = "", originalDeadline: String = "", dueDate: Date? = nil,
                status: ActionStatus = .open, dependencies: String = "") {
        self.text = text; self.owner = owner; self.originalDeadline = originalDeadline
        self.dueDate = dueDate; self.status = status; self.dependencies = dependencies
    }
}
public struct ActionRevision: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public let date: Date
    public let fields: ActionFields
    public let sourceProposal: ActionProposal?
    public let note: String
}
public struct TrackedAction: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public let projectID: UUID
    public var revisions: [ActionRevision]
    public var fields: ActionFields { revisions.last!.fields }
    public var sources: [ActionSource] {
        var seen = Set<String>()
        return revisions.flatMap { $0.sourceProposal?.sources ?? [] }.filter { seen.insert($0.id).inserted }
    }
    public func isOverdue(at date: Date, calendar: Calendar = .current) -> Bool {
        fields.status != .completed && fields.dueDate.map { calendar.startOfDay(for: $0) < calendar.startOfDay(for: date) } == true
    }
    public func isDueSoon(at date: Date, calendar: Calendar = .current) -> Bool {
        guard fields.status != .completed, let due = fields.dueDate,
              let end = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: date)) else { return false }
        return calendar.startOfDay(for: due) >= calendar.startOfDay(for: date) && calendar.startOfDay(for: due) <= end
    }
}
public struct MeetingProjectAssignment: Codable, Equatable, Sendable {
    public let meetingID: UUID
    public var projectID: UUID
}

/// Independent of report regeneration and of the lifetime of archived audio/meetings.
public struct ProjectLedger: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public private(set) var projects: [TrackedProject] = []
    public private(set) var assignments: [MeetingProjectAssignment] = []
    public private(set) var actions: [TrackedAction] = []
    public init() {}
    public func projectID(for meetingID: UUID) -> UUID? { assignments.first { $0.meetingID == meetingID }?.projectID }
    public mutating func addProject(name: String) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ActionProposal.normalized(name).isEmpty, !projects.contains(where: { ActionProposal.normalized($0.name) == ActionProposal.normalized(name) }) else {
            throw VerbaleError.message("Inserisci un nome progetto univoco e non vuoto.")
        }
        let project = TrackedProject(name: name); projects.append(project); return project.id
    }
    public mutating func assign(meetingID: UUID, to projectID: UUID?) throws {
        guard projectID == nil || projects.contains(where: { $0.id == projectID }) else { throw VerbaleError.message("Progetto non disponibile.") }
        guard self.projectID(for: meetingID) != projectID else { return }
        guard !actions.contains(where: { $0.sources.contains(where: { $0.meetingID == meetingID }) }) else {
            throw VerbaleError.message("La riunione ha già attività confermate: conserva il progetto per mantenere coerenti le fonti.")
        }
        assignments.removeAll { $0.meetingID == meetingID }
        if let projectID { assignments.append(MeetingProjectAssignment(meetingID: meetingID, projectID: projectID)) }
    }
    public func action(for proposal: ActionProposal) -> TrackedAction? {
        actions.first { $0.revisions.contains { $0.sourceProposal?.id == proposal.id } }
    }
    public func suggestedMatches(for proposal: ActionProposal) -> [TrackedAction] {
        guard let projectID = projectID(for: proposal.meetingID) else { return [] }
        let words = Set(ActionProposal.normalized(proposal.text).split(separator: " ").filter { $0.count > 2 })
        return actions.filter { action in
            guard action.projectID == projectID else { return false }
            let other = Set(ActionProposal.normalized(action.fields.text).split(separator: " ").filter { $0.count > 2 })
            return !words.isEmpty && Double(words.intersection(other).count) / Double(max(1, words.union(other).count)) >= 0.35
        }
    }
    /// Only an explicit PM confirmation can create/update an activity. Missing AI fields never erase PM edits.
    @discardableResult public mutating func confirm(_ proposal: ActionProposal, fields: ActionFields,
                                                    updating actionID: UUID? = nil, at date: Date = Date()) throws -> UUID {
        guard let projectID = projectID(for: proposal.meetingID), !proposal.sources.isEmpty else {
            throw VerbaleError.message("Assegna la riunione a un progetto e verifica le fonti della proposta.")
        }
        guard action(for: proposal) == nil else { throw VerbaleError.message("Questa proposta è già stata confermata. Modifica l’attività dal registro.") }
        try Self.validate(fields)
        let revision = ActionRevision(date: date, fields: fields, sourceProposal: proposal, note: actionID == nil ? "Attività confermata dal PM" : "Aggiornamento da riunione confermato dal PM")
        if let actionID {
            guard let i = actions.firstIndex(where: { $0.id == actionID && $0.projectID == projectID }) else { throw VerbaleError.message("Scegli un’attività dello stesso progetto.") }
            actions[i].revisions.append(revision); return actionID
        }
        // Exact duplicate descriptions require an explicit update of the existing task.
        guard !actions.contains(where: { $0.projectID == projectID && ActionProposal.normalized($0.fields.text) == ActionProposal.normalized(fields.text) }) else {
            throw VerbaleError.message("Esiste già un’attività con questa descrizione: scegli Aggiorna attività esistente.")
        }
        let action = TrackedAction(projectID: projectID, revisions: [revision]); actions.append(action); return action.id
    }
    public mutating func edit(_ id: UUID, fields: ActionFields, at date: Date = Date()) throws {
        try Self.validate(fields)
        guard let i = actions.firstIndex(where: { $0.id == id }) else { throw VerbaleError.message("Attività non disponibile.") }
        guard actions[i].fields != fields else { return }
        actions[i].revisions.append(ActionRevision(date: date, fields: fields, sourceProposal: nil, note: "Modifica del PM"))
    }
    private static func validate(_ fields: ActionFields) throws {
        guard !fields.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VerbaleError.message("La descrizione dell’attività è obbligatoria.") }
        guard fields.dueDate?.timeIntervalSince1970.isFinite != false else { throw VerbaleError.message("Scadenza non valida.") }
    }
    public func validate() throws {
        guard schemaVersion == 1, Set(projects.map(\.id)).count == projects.count,
              Set(actions.map(\.id)).count == actions.count,
              Set(assignments.map(\.meetingID)).count == assignments.count,
              assignments.allSatisfy({ a in projects.contains { $0.id == a.projectID } }),
              actions.allSatisfy({ a in !a.revisions.isEmpty && projects.contains { $0.id == a.projectID } }) else {
            throw VerbaleError.message("Il registro progetti non è valido o usa una versione non supportata. Il file originale è conservato.")
        }
        for action in actions { for revision in action.revisions { try Self.validate(revision.fields) } }
    }
}

public struct ProjectLedgerStore {
    public let file: URL
    public init(file: URL) { self.file = file }
    public func load() throws -> ProjectLedger {
        guard FileManager.default.fileExists(atPath: file.path) else { return ProjectLedger() }
        let ledger = try JSONDecoder().decode(ProjectLedger.self, from: Data(contentsOf: file))
        try ledger.validate(); return ledger
    }
    public func save(_ ledger: ProjectLedger) throws {
        try ledger.validate()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Prepare permissions before committing: a chmod failure must not replace the durable ledger.
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".project-ledger-" + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Default Date coding preserves exact revision timestamps across restarts.
        try encoder.encode(ledger).write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, file.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

public struct OperationalReport: Sendable {
    public let markdown: String
    public let actions: [ActionProposal]
}
