import SwiftUI
import FT8808Engine

/// WSJT-X-style QSO panel: the DX/report header, the Tx1–Tx6 message sequence
/// with the current phase highlighted, and CQ / Answer / Clear controls. Shows
/// the live QSO, or a preview built from the selected decode.
struct QSOPanel: View {
    @ObservedObject var model: WaterfallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // MIDDLE: operating controls + TX cycle selector.
            controls
            parityControl
            Divider()
            // BOTTOM: QSO status + the Tx1–Tx6 sequencer.
            header
            if let q = activeQSO {
                reports(q)
                sequence(q)
            } else {
                Text("Set your callsign in Settings to enable QSOs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// Always have a sequence to show: the live QSO, a preview from the selected
    /// decode, or a default CQ template (so the Sequencer is always visible).
    private var activeQSO: QSOSequencer? {
        if let q = model.displayQSO { return q }
        guard !model.myCall.isEmpty else { return nil }
        return QSOSequencer(callCQ: model.myCall, myGrid: model.myGrid)
    }

    private var panelStatus: (text: String, color: Color) {
        if model.qso != nil { return ("QSO", .green) }
        if model.selectedDecode?.call != nil { return ("PREVIEW", .orange) }
        return ("READY", .secondary)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(panelStatus.text)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(panelStatus.color)
            if let q = activeQSO, !q.dxCall.isEmpty {
                Text(q.dxCall)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                if let g = q.dxGrid {
                    Text(g).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            txChip
        }
    }

    /// Always-visible transmit state, so it's clear whether anything will go out.
    private var txChip: some View {
        let (label, color): (String, Color) =
            model.sending  ? ("SENDING",  .red) :
            model.txEnabled ? ("TX ARMED", .red) : ("TX OFF", .secondary)
        return Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private func reports(_ q: QSOSequencer) -> some View {
        HStack(spacing: 14) {
            Label(sign(q.reportToSend), systemImage: "arrow.up").labelStyle(.titleAndIcon)
                .foregroundStyle(.primary)
            Label(q.reportReceived.map(sign) ?? "––", systemImage: "arrow.down")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
    }

    // MARK: Tx1–Tx6 sequence

    private func sequence(_ q: QSOSequencer) -> some View {
        let dx = q.dxCall.isEmpty ? "..." : q.dxCall
        let rows: [(String, String, QSOSequencer.Phase)] = [
            ("Tx1", QSOMessages.reply(dx: dx, myCall: q.myCall, myGrid: q.myGrid), .reply),
            ("Tx2", QSOMessages.report(dx: dx, myCall: q.myCall, snr: q.reportToSend), .report),
            ("Tx3", QSOMessages.rogerReport(dx: dx, myCall: q.myCall, snr: q.reportToSend), .rReport),
            ("Tx4", QSOMessages.roger(dx: dx, myCall: q.myCall, rr73: true), .rr73),
            ("Tx5", QSOMessages.seventyThree(dx: dx, myCall: q.myCall), .seventyThree),
            ("Tx6", QSOMessages.cq(call: q.myCall, grid: q.myGrid, directive: nil), .cq),
        ]
        return VStack(alignment: .leading, spacing: 3) {
            Text("SEQUENCER")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(rows, id: \.0) { row in
                    let active = row.2 == q.phase
                    HStack(spacing: 6) {
                        Text(active ? "▸" : " ").foregroundStyle(.cyan)
                        Text(row.0).foregroundStyle(.secondary)
                        Text(row.1)
                            .foregroundStyle(active ? .primary : .secondary)
                            .fontWeight(active ? .bold : .regular)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.vertical, 1)
                    .padding(.horizontal, 4)
                    .background(active ? Color.cyan.opacity(0.14) : .clear)
                }
            }
            .padding(6)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: TX cycle (even/odd) selector — which slot CQ goes out on

    private var parityControl: some View {
        HStack(spacing: 8) {
            Text("TX cycle")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Picker("", selection: $model.txParity) {
                Text("Even :00/:30").tag(SlotParity.even)
                Text("Odd :15/:45").tag(SlotParity.odd)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .help("Which 15 s cycle to transmit CQ on (auto-set to the opposite slot when answering a decode)")
            Spacer()
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button { model.callCQ() } label: {
                Label(model.isCallingCQ ? "Stop CQ" : "Call CQ",
                      systemImage: model.isCallingCQ ? "stop.circle" : "megaphone")
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isCallingCQ ? .orange : .blue)
            .disabled(model.myCall.isEmpty || !model.txEnabled)
            .help(model.txEnabled ? (model.isCallingCQ ? "Stop calling CQ" : "Call CQ")
                                  : "Enable TX first")

            Button { model.haltTX() } label: {
                Label("Halt TX", systemImage: "stop.fill")
            }
            .tint(.red)
            .disabled(!model.sending)   // cuts the current over; only while sending
            .help("Stop the current transmission (stays armed)")

            Button { model.clearQSO() } label: {
                Label("Clear", systemImage: "xmark")
            }
            .disabled(model.qso == nil && model.selectedID == nil)

            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func sign(_ n: Int) -> String { n >= 0 ? "+\(n)" : "\(n)" }
}

/// Top of the right column: the RX/TX frequency field plus the 15 s cycle timer.
struct RxTxBar: View {
    @ObservedObject var model: WaterfallModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("RX / TX")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("Hz", value: freqBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text("Hz").font(.caption).foregroundStyle(.secondary)
                Stepper("", value: freqBinding, in: 0...10_000, step: 10)
                    .labelsHidden()
                Text("click waterfall to set")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button { model.autoPickTxFrequency() } label: {
                    Label("Find Free", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .help("Pick a clear TX frequency in the band's center")
            }
            CycleBar(model: model)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var freqBinding: Binding<Int> {
        Binding(get: { Int(model.txOffsetHz.rounded()) },
                set: { model.setTxOffset(Float($0)) })
    }
}
