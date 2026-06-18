import SwiftUI

/// A scrolling, selectable decode list — used twice: the full-band "passband"
/// list on the left and the filtered list on the right (mirrors the TUI's two
/// columns).
struct DecodeListView: View {
    let title: String
    let decodes: [Decode]
    let selectedID: UUID?
    let onSelect: (Decode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !title.isEmpty {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text("\(decodes.count)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(decodes) { d in
                        DecodeRow(d: d, selected: d.id == selectedID)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(d) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct DecodeRow: View {
    let d: Decode
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: "%+03d", Int(d.snr.rounded())))
                .foregroundStyle(snrColor(d.snr))
                .frame(width: 30, alignment: .trailing)
            Text(String(format: "%4d", Int(d.freq.rounded())))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
            Text(d.text)
                .foregroundStyle(d.toMe ? .green : (d.isCQ ? .yellow : .primary))
                .fontWeight(d.toMe ? .bold : .regular)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 1.5)
        .background(selected ? Color.accentColor.opacity(0.30) : .clear)
    }

    private func snrColor(_ snr: Float) -> Color {
        switch snr {
        case 0...:    return .green
        case -12..<0: return .primary
        default:      return .orange
        }
    }
}
