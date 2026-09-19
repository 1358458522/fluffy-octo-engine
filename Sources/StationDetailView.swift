import SwiftUI
import UIKit

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
            querySection
            headlineSection
            totalSection
            shiftSection
            productSection
            paySection
            tradesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(station.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    copyAll()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(result == nil)

                Button {
                    Task { await loadAll() }
                } label: {
                    if isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(isLoading)
            }
        }
        .refreshable { await loadAll() }
        // 注意：进入本页不自动取数。云库连接必须由用户手动触发（点下方「查询本站」或右上刷新），
        // 避免"点开站点即连库"在自签真机上触发闪退。
        .sheet(isPresented: $showShare) { ShareSheet(items: exportItems) }
        .alert(item: $alert) { payload in
            Alert(title: Text(payload.title), message: Text(payload.message), dismissButton: .default(Text("好")))
        }
    }

    // MARK: 手动取数入口（进页面不自动连库）

    private var querySection: some View {
        Section {
            Button {
                Task { await loadAll() }
            } label: {
                HStack {
                    Label(result == nil ? "查询本站当日数据（\(date)）" : "重新查询本站当日数据（\(date)）",
                          systemImage: "arrow.down.circle")
                    Spacer()
                    if isLoading { ProgressView() }
                }
            }
            .disabled(isLoading)

            Text("只连本站这一个云库，串行执行，不并发、不影响其它站点。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: 抬头（数据源 / 营业日期 / 站点状态）

    private var headlineSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if let result, let error = result.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    HStack(spacing: 12) {
                        Label("数据源 云端", systemImage: "cloud")
                        Label("营业日期 \(date)", systemImage: "calendar")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if let result {
                        Text(result.timing.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(result.timing.displayColor.opacity(0.12))
                            .foregroundStyle(result.timing.displayColor)
                            .clipShape(Capsule())
                    }
                }

                Text("云库 \(station.displayAddress) · 库 \(station.db)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: 全天合计

    private var totalSection: some View {
        Section("全天合计") {
            HStack {
                Text("营业额(元)")
                Spacer()
                Text(Fmt.money(result?.amount ?? 0))
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
            HStack {
                Text("油量(升)")
                Spacer()
                Text(Fmt.volume(result?.volume ?? 0))
                    .monospacedDigit()
            }
            HStack {
                Text("交易笔数")
                Spacer()
                Text("\(result?.count ?? 0)")
                    .monospacedDigit()
            }
        }
    }

    // MARK: 各班次明细（状态：已交班绿字 / 未交班红字）

    private var shiftSection: some View {
        Section("各班次明细") {
            if let shifts = result?.shifts, !shifts.isEmpty {
                ForEach(shifts) { shift in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("班次 \(shift.shift)")
                            Spacer()
                            Text("¥" + Fmt.money(shift.amount))
                                .monospacedDigit()
                        }

                        HStack(spacing: 10) {
                            Text("\(shift.count) 笔 · \(Fmt.volume(shift.volume)) 升")
                            Spacer()
                            Text(shift.timing.rawValue)
                                .foregroundStyle(shift.timing.displayColor)
                                .fontWeight(shift.timing.isClosed ? .regular : .semibold)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if !shift.period.isEmpty {
                            Text("时段 " + shift.period)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
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

    // MARK: 全天按油品

    private var productSection: some View {
        Section("全天按油品") {
            if let products = result?.products, !products.isEmpty {
                ForEach(products) { item in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name.isEmpty ? item.code : item.name)
                            Text(item.code)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("¥" + Fmt.money(item.amount))
                                .monospacedDigit()
                            Text("\(Fmt.volume(item.volume)) 升 · \(item.count) 笔")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text(result?.error == nil ? "当日暂无按油品汇总" : "读取失败，请下拉重试")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 全天按支付方式

    private var paySection: some View {
        Section("全天按支付方式") {
            if let pays = result?.pays, !pays.isEmpty {
                ForEach(pays) { item in
                    HStack(spacing: 10) {
                        Text(item.payMode.isEmpty ? "未标记" : item.payMode)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("¥" + Fmt.money(item.amount))
                                .monospacedDigit()
                            Text("\(Fmt.volume(item.volume)) 升 · \(item.count) 笔")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text(result?.error == nil ? "当日暂无按支付方式汇总" : "读取失败，请下拉重试")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 逐笔明细

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

    private func loadAll() async {
        guard !isLoading else { return }
        isLoading = true
        Diag.log("【详情】开始查询 \(station.name) \(date)")
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

    /// 复制与电脑端详情窗口一致的文本
    private func copyAll() {
        guard let result else { return }
        UIPasteboard.general.string = DayReportText.make(result: result, station: station)
        alert = AlertPayload(title: "已复制", message: "详情已复制到剪贴板，可直接粘贴到微信或备忘录。")
    }
}
