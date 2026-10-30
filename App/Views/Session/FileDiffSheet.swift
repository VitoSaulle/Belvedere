import BelvedereCore
import SwiftUI

/// Le modifiche fatte a un file nella sessione, una accanto all'altra in ordine di tempo.
struct FileDiffSheet: View {
    let file: FileChange
    let transcript: String
    @Environment(\.dismiss) private var dismiss
    @State private var hunks: [[DiffLine]]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text((file.path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold))
                    Text(file.path).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("+\(file.added)").foregroundStyle(Theme.done)
                Text("−\(file.removed)").foregroundStyle(Theme.danger)
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .padding(14)
            Divider()
            content
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 420, idealHeight: 620)
        .task {
            let path = transcript, target = file.path
            hunks = await Task.detached { (try? FileEdits.load(transcript: path, file: target)) ?? [] }.value
        }
    }

    @ViewBuilder private var content: some View {
        if let hunks, hunks.isEmpty {
            ContentUnavailableView("Modifiche non trovate nella trascrizione", systemImage: "doc.text.magnifyingglass")
        } else if let hunks {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hunks.indices, id: \.self) { index in
                        if index > 0 { Divider().padding(.vertical, 8) }
                        ForEach(hunks[index].indices, id: \.self) { row(hunks[index][$0]) }
                    }
                }
                .padding(.vertical, 8)
                .textSelection(.enabled)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ line: DiffLine) -> some View {
        let sign = line.kind == .added ? "+" : line.kind == .removed ? "−" : " "
        return HStack(alignment: .top, spacing: 8) {
            Text(line.number.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
            Text(sign).foregroundStyle(color(line.kind) ?? .secondary)
            Text(line.text.isEmpty ? " " : line.text).fixedSize()
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background((color(line.kind) ?? .clear).opacity(0.13))
    }

    private func color(_ kind: DiffLine.Kind) -> Color? {
        switch kind {
        case .added: Theme.done
        case .removed: Theme.danger
        case .context: nil
        }
    }
}
