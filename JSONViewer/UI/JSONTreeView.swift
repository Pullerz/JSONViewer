import SwiftUI

struct JSONTreeView: View {
    let root: JSONTreeNode?
    var onSelect: (JSONTreeNode) -> Void

    var body: some View {
        Group {
            if let root {
                ScrollView {
                    OutlineGroup([root], children: \.children) { node in
                        JSONTreeRow(node: node)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect(node)
                            }
                            .padding(.vertical, 2)
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No content")
                        .font(.headline)
                    Text("Open or paste JSON to view structure.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct JSONTreeRow: View {
    let node: JSONTreeNode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(node.displayKey)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            if node.isLeaf {
                Text(node.previewValue)
                    .font(.system(.body, design: .monospaced))
            } else {
                Text(node.children?.first?.key?.hasPrefix("[") == true ? "[…]" : "{…}")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}