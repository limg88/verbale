import Foundation

/// A long report is composed from bounded, disjoint evidence sets. Full evidence
/// belongs to the detailed sections; the executive overview deliberately samples
/// whole records and never substitutes for those sections.
enum ReportComposition {
    struct Section {
        let title:String
        let instruction:String
        let inputs:[String]
        var overview = false
    }
    static let definitions:[(String,Set<String>,String)] = [
        ("Fatti e avanzamenti",["fact"],"Distingui completato, in corso e pianificato solo quando esplicito. Raggruppa per tema."),
        ("Decisioni",["decision"],"Riporta le decisioni effettive e le conseguenze dichiarate."),
        ("Attività e responsabilità",["action"],"Produci una tabella Markdown completa: Attività | Responsabile | Scadenza | Stato e dipendenze | Fonti. Includi intestazione e separatore anche se questa è una parte della sezione."),
        ("Rischi e problemi aperti",["risk"],"Distingui rischi futuri e problemi presenti. Riporta impatti, contromisure e titolari solo quando espliciti."),
        ("Opportunità",["opportunity"],"Distingui benefici e proposte dagli impegni effettivi."),
        ("Punti da chiarire",["question","conflict"],"Conserva domande aperte, divergenze, negazioni e correzioni; non risolvere i conflitti per supposizione."),
        ("Note personali",["note"],"Distingui gli appunti dell'utente dalle parole pronunciate e dalle decisioni della call.")
    ]
    static func body(_ text:String,title:String)->String {
        var lines = text.components(separatedBy:.newlines)
        func normalized(_ value:String)->String {
            value.trimmingCharacters(in:CharacterSet(charactersIn:"#*_ \t")).folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"it_IT"))
        }
        while let first = lines.first,first.trimmingCharacters(in:.whitespaces).isEmpty { lines.removeFirst() }
        if let first = lines.first,normalized(first) == normalized(title) { lines.removeFirst() }
        return lines.joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
    }
    static func chunks(_ facts:[ReportCapsule.Fact],limit:Int) throws -> [String] {
        var result:[String] = [],current:[ReportCapsule.Fact] = []
        for fact in facts {
            let candidate = try ReportCapsule(facts:current+[fact]).encoded()
            if candidate.utf8.count <= limit { current.append(fact); continue }
            guard !current.isEmpty else { throw ReportServiceError(kind:.intermediateCapacity,status:0,retryAfter:nil) }
            result.append(try ReportCapsule(facts:current).encoded()); current = [fact]
            guard try ReportCapsule(facts:current).encoded().utf8.count <= limit else {
                throw ReportServiceError(kind:.intermediateCapacity,status:0,retryAfter:nil)
            }
        }
        if !current.isEmpty { result.append(try ReportCapsule(facts:current).encoded()) }
        return result
    }
    static func prefix(title:String,instruction:String)->String {
        "SEZIONE DEL RAPPORTO: \(title)\n\(instruction)\nRECORD DELLA RIUNIONE:\n"
    }
    static func plan(_ capsule:ReportCapsule,limit:Int) throws -> [Section] {
        var sections:[Section] = []
        for (title,kinds,instruction) in definitions {
            let facts = capsule.facts.filter { kinds.contains($0.kind) }
            let prefix = prefix(title:title,instruction:instruction)
            let inputs = try chunks(facts,limit:limit-prefix.utf8.count).map { prefix+$0 }
            sections.append(Section(title:title,instruction:instruction,inputs:inputs))
        }
        // This subset is used ONLY for the brief overview. Every record, including
        // those not selected here, has already been placed in a detailed section.
        let instruction = "Scrivi una breve sintesi operativa in 4–6 punti. Questi record sono una selezione non esaustiva: non dedurre lo stato complessivo del progetto né l'assenza di rischi o attività. I dettagli completi sono nelle altre sezioni. Non inventare priorità."
        let overviewPrefix = prefix(title:"Sintesi per il project manager",instruction:instruction)
        let kinds = ["decision","risk","action","conflict","question","opportunity","fact","note"]
        let groups = kinds.map { kind in capsule.facts.filter { $0.kind == kind } }
        var selected:[ReportCapsule.Fact] = []
        for index in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where index < group.count {
                let candidate = selected+[group[index]]
                if try overviewPrefix.utf8.count+ReportCapsule(facts:candidate).encoded().utf8.count <= limit { selected = candidate }
            }
        }
        let overview = Section(title:"Sintesi per il project manager",instruction:instruction,
            inputs:[try overviewPrefix+ReportCapsule(facts:selected).encoded()],overview:true)
        return [overview]+sections
    }
}
