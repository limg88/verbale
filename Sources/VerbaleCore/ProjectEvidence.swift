import Foundation

public enum ReportStyle:String,CaseIterable,Identifiable,Sendable {
    case operational,detailed
    public var id:String { rawValue }
    public var label:String { self == .operational ? "Operativo":"Esteso" }
}
struct ProjectEvidence:Codable {
    struct Item:Codable,Hashable {
        let kind:String
        let text:String
        let refs:[String]
        var owner:String?
        var deadline:String?
        var status:String?
        var dependencies:String?
        var commitment:String?
    }
    var facts:[Item]
    var overview:[Item]?
    static func parse(_ text:String,validSources:Set<String>,summary:Bool = false) throws -> Self {
        var json = text.trimmingCharacters(in:.whitespacesAndNewlines)
        if (json.hasPrefix("```json\n") || json.hasPrefix("```\n")),json.hasSuffix("```") {
            json = String(json.dropFirst(json.hasPrefix("```json\n") ? 8:4).dropLast(3)).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        guard let data = json.data(using:.utf8),var value = try? JSONDecoder().decode(Self.self,from:data) else {
            throw ReportServiceError(kind:.invalidResponse,status:200,retryAfter:nil)
        }
        let kinds:Set<String> = ["fact","decision","action","risk","opportunity","question","note","conflict","summary"]
        func valid(_ item:Item)->Bool {
            kinds.contains(item.kind) && !item.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !item.refs.isEmpty && Set(item.refs).isSubset(of:validSources)
            && (item.commitment == nil || ["agreed","proposed","unclear"].contains(item.commitment!))
        }
        guard value.facts.allSatisfy({ valid($0) && $0.kind != "summary" }),(value.overview ?? []).allSatisfy(valid),
              !summary || !(value.overview ?? []).isEmpty else { throw ReportServiceError(kind:.invalidResponse,status:200,retryAfter:nil) }
        value.facts = value.facts.map { source in
            var item = source
            if item.refs.contains("N") { item = Item(kind:"note",text:item.text,refs:item.refs,owner:item.owner,deadline:item.deadline,status:item.status,dependencies:item.dependencies,commitment:item.commitment) }
            else if item.kind == "note" { item = Item(kind:item.commitment != nil ? "action":"fact",text:item.text,refs:item.refs,owner:item.owner,deadline:item.deadline,status:item.status,dependencies:item.dependencies,commitment:item.commitment) }
            return item
        }
        return value
    }
    func encoded() throws -> String {
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        return String(decoding:try encoder.encode(self),as:UTF8.self)
    }
    static func merge(_ values:[Self])->Self {
        var result:[Item] = [],indices:[Item:Int] = [:]
        for item in values.flatMap(\.facts) {
            var key = item;key = Item(kind:key.kind,text:key.text,refs:[],owner:key.owner,deadline:key.deadline,status:key.status,dependencies:key.dependencies,commitment:key.commitment)
            if let index = indices[key] { var old = result[index];old = Item(kind:old.kind,text:old.text,refs:Array(Set(old.refs+item.refs)).sorted(),owner:old.owner,deadline:old.deadline,status:old.status,dependencies:old.dependencies,commitment:old.commitment);result[index] = old }
            else { indices[key] = result.count;result.append(item) }
        }
        return Self(facts:result,overview:values.count == 1 ? values[0].overview:nil)
    }
}
struct ReportSourceBatch {
    struct Fragment { let token:String;let prefix:String;let body:String }
    var fragments:[Fragment]
    var text:String { fragments.map { $0.prefix+$0.body+"\n\n" }.joined() }
    var refs:Set<String> { Set(fragments.map(\.token)) }
    static func pack(_ fragments:[Fragment],limit:Int)->[Self] {
        var batches:[Self] = [],current:[Fragment] = [],bytes = 0
        for source in fragments {
            var remaining = source.body[...]
            while !remaining.isEmpty {
                let budget = max(1,limit-source.prefix.utf8.count-2)
                let scalars = remaining.unicodeScalars
                var end = scalars.startIndex,count = 0
                while end < scalars.endIndex,count+scalars[end].utf8.count <= budget { count += scalars[end].utf8.count;end = scalars.index(after:end) }
                if end == scalars.startIndex { end = scalars.index(after:end) }
                let body = String(remaining[..<end]);remaining = remaining[end...]
                let size = source.prefix.utf8.count+body.utf8.count+2
                if bytes+size > limit && !current.isEmpty { batches.append(Self(fragments:current));current = [];bytes = 0 }
                current.append(Fragment(token:source.token,prefix:source.prefix,body:body));bytes += size
            }
        }
        if !current.isEmpty { batches.append(Self(fragments:current)) }
        return batches
    }
}
