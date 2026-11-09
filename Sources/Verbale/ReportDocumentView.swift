import SwiftUI
import VerbaleCore

/// Native rendering of the blocks commonly used in meeting reports, including tables.
/// Inline citations remain links handled by the meeting's OpenURLAction.
struct ReportDocumentView: View, Equatable {
    static func ==(lhs:Self,rhs:Self)->Bool {lhs.text==rhs.text}
    let text: String
    private enum Block { case line(String), table([[String]]) }
    private func cells(_ line: String) -> [String] {
        ReportMarkdown.cells(line)
    }

    private var blocks: [Block] {
        let lines = text.components(separatedBy: .newlines)
        var result: [Block] = [], index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.contains("|"), index + 1 < lines.count {
                let separators = cells(lines[index + 1])
                if separators.count > 1, separators.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) {
                    var rows = [cells(line)]; index += 2
                    while index < lines.count, lines[index].contains("|") { rows.append(cells(lines[index])); index += 1 }
                    result.append(.table(rows)); continue
                }
            }
            result.append(.line(line)); index += 1
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .line(let line): lineView(line)
                case .table(let rows): table(rows)
                }
            }
        }.font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
    }
    private func table(_ rows: [[String]]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow(alignment: .top) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(.init(cell)).fontWeight(index == 0 ? .semibold : .regular).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }.padding(14).background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private func lineView(_ line: String) -> some View {
        if line.isEmpty { Color.clear.frame(height: 4) }
        else if line == "---" || line == "***" { Divider().padding(.vertical, 6) }
        else if line.hasPrefix("#") {
            let level = line.prefix(while: { $0 == "#" }).count
            let title = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
            Text(.init(title)).font(.system(size: level == 1 ? 22 : level == 2 ? 18 : 15, weight: .semibold)).padding(.top, 10)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 10) { Text("•").foregroundStyle(.secondary); Text(.init(String(line.dropFirst(2)))).frame(maxWidth: .infinity, alignment: .leading) }
        } else if line.hasPrefix("> ") {
            Text(.init(String(line.dropFirst(2)))).foregroundStyle(.secondary).padding(.leading, 12)
        } else { Text(.init(line)).frame(maxWidth: .infinity, alignment: .leading) }
    }
}
