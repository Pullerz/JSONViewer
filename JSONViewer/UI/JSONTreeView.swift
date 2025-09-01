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
                            .frame(maxWidth: .infinity, alignment: .leading)
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
        HStack(alignment: .top, spacing: 10) {
            Text(node.displayKey)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 140, alignment: .leading)

            if node.isLeaf {
                Text(node.previewValue)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(node.children?.first?.key?.hasPrefix("[") == true ? "[…]" : "{…}")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}