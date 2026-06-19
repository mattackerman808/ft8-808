import SwiftUI

/// A scrolling, selectable decode list — used twice: the full-band "passband"
/// list on the left and the filtered list on the right (mirrors the TUI's two
/// columns).
struct DecodeListView: View {
    let title: String
    let decodes: [Decode]
    let selectedID: UUID?
    let myCall: String
    let worked: Set<String>          // worked-before callsigns (uppercased)
    let onSelect: (Decode) -> Void

    // Auto-follow new decodes only while pinned to the bottom; pause when the
    // operator scrolls up to read/select, resume when they return to the bottom.
    @State private var atBottom = true

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
            GeometryReader { outer in
                let viewportH = outer.size.height   // capture as a Sendable value
                ScrollViewReader { proxy in
                    ScrollView {
                        // Plain VStack (not Lazy): off-screen rows must stay laid out
                        // so the bottom-of-content measurement keeps updating while
                        // scrolled up — otherwise auto-follow can't tell it's paused.
                        VStack(alignment: .leading, spacing: 1) {
                            // Oldest at top, newest at the bottom (chronological, scrolls down).
                            ForEach(Array(decodes.reversed())) { d in
                                DecodeRow(d: d, selected: d.id == selectedID,
                                          myCall: myCall, worked: worked)
                                    .id(d.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onSelect(d) }
                            }
                        }
                        .padding(.vertical, 4)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ContentBottomKey.self,
                                                   value: g.frame(in: .named("decodeScroll")).maxY)
                        })
                    }
                    .coordinateSpace(name: "decodeScroll")
                    // The content's bottom edge sits at ≈viewport height when scrolled
                    // to the bottom, and grows past it as you scroll up.
                    .onPreferenceChange(ContentBottomKey.self) { bottom in
                        // onPreferenceChange's closure is @Sendable on some SDKs;
                        // hop to the main actor to mutate the @State.
                        Task { @MainActor in atBottom = bottom <= viewportH + 36 }
                    }
                    // Follow new decodes downward, but only while pinned to the bottom.
                    // `decodes.first` is the newest (model inserts at 0); after the
                    // reverse it sits at the bottom.
                    .onChange(of: decodes.first?.id) { newest in
                        guard let newest, atBottom else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(newest, anchor: .bottom) }
                    }
                    .onAppear {
                        if let newest = decodes.first?.id { proxy.scrollTo(newest, anchor: .bottom) }
                    }
                }
            }
            .padding(.bottom, 12)   // keep the last row off the window's bottom edge
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Reports the decode content's bottom edge (Y) in the scroll viewport's
/// coordinate space, so we can tell whether the list is scrolled to the bottom.
private struct ContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct DecodeRow: View {
    let d: Decode
    let selected: Bool
    let myCall: String
    let worked: Set<String>

    var body: some View {
        Group {
            if d.isLogged {
                // Completed-QSO banner: a green "✓ QSO … sent … rcvd …" line.
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.green).frame(width: 3)
                    Text(d.text).foregroundStyle(.green).fontWeight(.bold).lineLimit(1)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 6) {
                    // Even=blue / odd=orange slot marker (which 15 s cycle we heard it in).
                    RoundedRectangle(cornerRadius: 1)
                        .fill(d.isEvenSlot ? SlotColors.even : SlotColors.odd)
                        .frame(width: 3)
                    Text(d.isTx ? "Tx" : String(format: "%+03d", Int(d.snr.rounded())))
                        .foregroundStyle(d.isTx ? .red : .cyan)
                        .frame(width: 30, alignment: .trailing)
                    Text(String(format: "%4d", Int(d.freq.rounded())))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                    colorizedText
                        .fontWeight(d.toMe || d.isTx ? .bold : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 1.5)
        .background(rowBackground)
    }

    private var rowBackground: Color {
        if selected { return Color.accentColor.opacity(0.30) }
        if d.isLogged { return Color.green.opacity(0.12) }   // logged-QSO banner
        if d.isTx { return Color.red.opacity(0.12) }         // our own transmission
        return .clear
    }

    /// Per-token colouring like the TUI: my own call green, worked-before calls
    /// red, everything else the base colour (CQ lines yellow, otherwise default).
    private var colorizedText: Text {
        let base: Color = d.isCQ ? .yellow : .primary
        let me = myCall.uppercased()
        var out = Text("")
        for (i, tok) in d.text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let up = tok.uppercased()
            let color: Color = (!me.isEmpty && up == me) ? .green
                             : (worked.contains(up) ? .red : base)
            if i > 0 { out = out + Text(" ") }
            out = out + Text(String(tok)).foregroundColor(color)
        }
        return out
    }
}
