import Foundation

enum ProjectReportRenderer {
    static func plain(_ text:String)->String {
        var value = text.replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" ")
        value = value.replacingOccurrences(of:"\\",with:"\\\\")
        for c in ["[","]","*","_","`","|","<",">"] { value = value.replacingOccurrences(of:c,with:"\\"+c) }
        return value
    }
    static func citations(_ item:ProjectEvidence.Item)->String { item.refs.map { "[[\($0)]]" }.joined(separator:" ") }
    static func fallbackOverview(_ evidence:ProjectEvidence)->[ProjectEvidence.Item] {
        let kinds = ["decision","risk","action","conflict","fact","question","opportunity"]
        return Array(kinds.compactMap { kind in evidence.facts.first { $0.kind == kind } }.prefix(6))
    }
    struct SummaryInput { let text:String;let refs:Set<String> }
    static func summaryInput(_ evidence:ProjectEvidence,limit:Int) throws -> SummaryInput {
        let prefix = "SINTESI OPERATIVA DAI RECORD:\n",suffix = "\n"+ProjectReportPrompt.summary
        let available = limit-prefix.utf8.count-suffix.utf8.count
        let all = try evidence.encoded()
        if all.utf8.count <= available { return SummaryInput(text:prefix+all+suffix,refs:Set(evidence.facts.flatMap(\.refs))) }
        var selected:[ProjectEvidence.Item] = []
        let groups = ["decision","risk","action","conflict","question","opportunity","fact","note"].map { kind in evidence.facts.filter { $0.kind == kind } }
        for index in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where index < group.count {
                let candidate = selected+[group[index]]
                if try ProjectEvidence(facts:candidate).encoded().utf8.count <= available { selected = candidate }
            }
        }
        guard !selected.isEmpty || evidence.facts.isEmpty else { throw ReportServiceError(kind:.intermediateCapacity,status:0,retryAfter:nil) }
        return try SummaryInput(text:prefix+ProjectEvidence(facts:selected).encoded()+suffix,refs:Set(selected.flatMap(\.refs)))
    }
    static func render(_ evidence:ProjectEvidence,overview:[ProjectEvidence.Item])->String {
        // Split into typed steps: as one expression this exceeded the type-checker's time limit on Swift 6.1.
        let overviewLines: [String] = overview.map { item -> String in
            let prefix: String = item.refs.contains("N") ? "Nota personale — " : ""
            return "- " + prefix + plain(item.text) + " " + citations(item)
        }
        let overviewText: String = overview.isEmpty ? "Non emersi elementi sufficienti dalle fonti disponibili." : overviewLines.joined(separator:"\n")
        var sections: [String] = ["## Sintesi per il project manager\n\n" + overviewText]
        for (title,kinds,_) in ReportComposition.definitions {
            let items = evidence.facts.filter { kinds.contains($0.kind) }
            if items.isEmpty && title == "Note personali" { continue }
            var body:String
            if items.isEmpty { body = "Non emersi dalle fonti disponibili." }
            else if kinds.contains("action") {
                let rows = items.map { item -> String in
                    func field(_ value:String?,_ unknown:String)->String { plain(value.flatMap { $0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil:$0 } ?? unknown) }
                    let commitment = ["agreed":"Concordata","proposed":"Proposta","unclear":"Da confermare"][item.commitment ?? "unclear"]!
                    var status = [field(item.status,"Non indicato"),commitment]
                    if let dependencies = item.dependencies,!dependencies.isEmpty { status.append("Dipende da: "+plain(dependencies)) }
                    return "| "+[plain(item.text),field(item.owner,"Da assegnare"),field(item.deadline,"Non indicata"),status.joined(separator:"; "),citations(item)].joined(separator:" | ")+" |"
                }
                body = "| Attività | Responsabile | Scadenza | Stato e dipendenze | Fonti |\n| --- | --- | --- | --- | --- |\n"+rows.joined(separator:"\n")
            } else {
                body = items.map { item in
                    var details:[String] = []
                    for (label,value) in [("Persona indicata",item.owner),("Scadenza indicata",item.deadline),("Stato dichiarato",item.status),("Dipendenze",item.dependencies)] {
                        if let value,!value.isEmpty { details.append(label+": "+plain(value)) }
                    }
                    return "- "+plain(item.text)+(details.isEmpty ? "":" ("+details.joined(separator:"; ")+")")+" "+citations(item)
                }.joined(separator:"\n")
            }
            sections.append("## "+title+"\n\n"+body)
        }
        return sections.joined(separator:"\n\n")
    }
}

public enum ReportMarkdown {
    /// Split table cells without treating escaped pipes inside technical text as columns.
    public static func cells(_ line:String)->[String] {
        var value = line.trimmingCharacters(in:.whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        var result:[String] = [],current = "",escaped = false
        for c in value {
            if c == "|" && !escaped { result.append(current.trimmingCharacters(in:.whitespaces));current = "" }
            else { current.append(c) }
            if c == "\\" { escaped.toggle() } else { escaped = false }
        }
        result.append(current.trimmingCharacters(in:.whitespaces))
        return result
    }
}
