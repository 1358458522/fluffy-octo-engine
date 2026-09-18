import SwiftUI

struct StationDetailView: View {
    let station: Station
    let date: String

    @State private var result: StationResult?
    @State private var trades: [TradeRow] = []
    @State private var isLoading = false
    @State private var isLoadingTrades = false
    @State private var showShare = false
    @State private var exportItems: [Any] = []
    @State private var alert: AlertPayload?

    init(station: Station, initial: StationResult?, date: String) {
        self.station = station
        self.date = date
        _result = State(initialValue: initial)
    }

    var body: some View {
        List {
            headlineSection
            shiftSection
            tradesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(station.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await loadAll() }
                } label: {
                    if isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(isLoading)
            }
        }
        .refreshable { await loadAll() }
        .task {
            if result == nil { await loadAll() }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: exportItems) }
        .alert(item: $alert) { payload in
            Alert(title: Text(payload.title), message: Text(payload.message), dismissButton: .default(Text("好")))
        }
    }

    // MARK: 子视图

    private var headlineSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(result?.error ?? "营业日期 \(date)")
                    .font(result?.error == nil ? .footnote : .caption)
                    .foregroundStyle(result?.error == nil ? Color.secondary : Color.red)

                Text("¥ " + Fmt.money(result?.amount ?? 0))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()

                HStack(spacing: 14) {
                    Label("\(result?.count ?? 0) 笔", systemImage: "number")
                    Label("\(Fmt.volume(result?.volume ?? 0)) 升", systemImage: "drop.fill")
                    if let result, result.error == nil {
                        Label(result.timing.rawValue, systemImage: "clock")
                            .foregroundStyle(result.timing == .closed ? .green : .orange)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                Text("云库 \(station.displayAddress) · 库 \(station.db)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    private var shiftSection: some View {
        Section("班次") {
            if let shifts = result?.shifts, !shifts.isEmpty {
                ForEach(shifts) { shift in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("第 \(shift.shift) 班").font(.callout)
                            Text(timeRange(shift))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("¥" + Fmt.money(shift.amount)).monospacedDigit()
                            Text("\(shift.count) 笔 · \(Fmt.volume(shift.volume)) 升")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button {
                            Task { await loadTrades(shift: shift.shift) }
                        } label: {
                            Label("明细", systemImage: "list.bullet")
                        }
                        .tint(.blue)
                    }
                }
            } else {
                Text(result?.error == nil ? "当日暂无交易记录" : "读取失败，请下拉重试")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tradesSection: some View {
        Section("逐笔明细") {
            Button {
                Task { await loadTrades(shift: nil) }
            } label: {
                HStack {
                    Label("加载当日全部明细（最多 500 笔）", systemImage: "doc.text.magnifyingglass")
                    Spacer()
                    if isLoadingTrades { ProgressView() }
                }
            }
            .disabled(isLoadingTrades)

            if !trades.isEmpty {
                Button {
                    exportTrades()
                } label: {
                    Label("导出这 \(trades.count) 笔为 CSV", systemImage: "square.and.arrow.up")
                }

                ForEach(trades.prefix(50)) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.tradeTime).font(.caption).monospacedDigit()
                            Text("第 \(row.shift) 班").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("¥" + Fmt.money(row.amount)).font(.caption).monospacedDigit()
                        }
                        HStack {
                            Text("\(row.productName) · \(row.fipID)").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Fmt.volume(row.volume)) 升 · \(row.paidState)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if trades.count > 50 {
                    Text("仅显示前 50 笔，导出可拿到全部 \(trades.count) 笔")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: 逻辑

    private func timeRange(_ shift: ShiftRevenue) -> String {
        let start = shift.firstTime ?? "--"
        let end = shift.lastTime ?? "--"
        return "\(start) → \(end)"
    }

    private func loadAll() async {
        isLoading = true
        result = await RevenueService.refresh(station, date: date)
        isLoading = false
    }

    private func loadTrades(shift: Int?) async {
        isLoadingTrades = true
        do {
            let rows = try await DatabaseService.fetchTrades(station, date: date, shift: shift)
            trades = rows
            if rows.isEmpty {
                alert = AlertPayload(title: "没有数据", message: "该范围内没有查到交易记录。")
            }
        } catch {
            alert = AlertPayload(title: "读取失败", message: "\(error)")
        }
        isLoadingTrades = false
    }

    private func exportTrades() {
        do {
            let url = try CSVExporter.writeTrades(trades, stationName: station.name, date: date, shift: nil)
            exportItems = [url]
            showShare = true
        } catch {
            alert = AlertPayload(title: "导出失败", message: error.localizedDescription)
        }
    }
}
