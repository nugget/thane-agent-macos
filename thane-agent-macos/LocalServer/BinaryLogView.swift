import SwiftUI

/// Scrollable log tail for BinaryManager output.
struct BinaryLogView: View {
    let logLines: [BinaryManager.LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(logLines) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.isError ? .red : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .background(Color(.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: logLines.count) {
                if let last = logLines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}
