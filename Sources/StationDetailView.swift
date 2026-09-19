import SwiftUI
import UIKit

/// 站点详情：单站取数。
/// - 本页自带「营业日期」选择，可查任意一天；
/// - 不做自动取数、不做下拉刷新：任何云库连接都必须由用户点按钮手动触发，串行执行，避免闪退；
/// - 全天按油品只统计升数，不再展示按支付方式。
struct StationDetailView: View {
    let station: Station

    @State private var date: Date
    @State private var result: StationResult?
    @State private var trades: [TradeRow] = []
    @State private var isLoading = false
    @State private var isLoadingTrades = false
    @State private var showShare = false
    @State private var exportItems: [Any] = []
    @State private var alert: AlertPayload?

    init(station: Station) {
        self.station = station
        _date = State(initialValue: Date())
    }

    /// 当前所选营业日期（yyyy-MM-dd）
    private var dateText: String { Fmt.dateFormatter.string(from: date) }

    /// 已查到的结果是否还是当前所选日期的
    private var isStale: Bool {
        guard let result else { return false }
        return result.date != dateText
    }

    var body: some View {
        List {
            querySection
            overviewSection
            summarySection
            shiftSection
            productSection
            tradesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(station.name.isEmpty ? "站点详情" : station.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    copyAll()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(result == nil)
                .accessibilityLabel("复制详情")

                Button {
                    Task { await loadAll() }
                } label: {
                    if isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(isLoading)
                .accessibilityLabel("重新查询")
            }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: exportItems) }
        .alert(item: $alert) { payload in
            Alert(title: Text(payload.title), message: Text(payload.message), dismissButton: .default(Text("好")))
        }
    }

    // MARK: - 查询（日期 + 手动取数）

    private var querySection: some View {
        Section {
            HStack {
                Label("营业日期", systemImage: "calendar")
                Spacer()
                DatePicker("营业日期", selection: $date, displayedComponents: .date)
                    .labelsHidden()
            }

            HStack(spacing: 8) {
                quickDateButton("今天", offset: 0)
                quickDateButton("昨天", offset: -1)
                quickDateButton("前天", offset: -2)
            }

            Button {
                Task { await loadAll() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(result == nil ? "查询当日数据" : "重新查询当日数据")
                    Spacer()
                    if isLoading { ProgressView() }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading)

            if isStale {
                Label("当前结果是 \(result?.date ?? "") 的，日期已改为 \(dateText)，请重新查询",
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("查询")
        } footer: {
            Text("只连本站这一个云库，串行执行，不并发、不影响其它站点。")
        }
    }

    private func quickDateButton(_ title: String, offset: Int) -> some View {
        let target = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let selected = Fmt.dateFormatter.string(from: target) == dateText
        return Button {
            date = target
        } label: {
            Text(title)
                .font(.footnote)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(selected ? Color.accentColor : Color.secondary)
    }

    // MARK: - 站点信息

    private var overviewSection: some View {
        Section("状态") {
            HStack {
                Text("交班状态")
                Spacer()
                if let result {
                    StatusBadge(timing: result.timing)
                } else {
                    Text("未查询")
                        .foregroundStyle(.tertiary)
                }
            }

            if let result {
                InfoRow(title: "取数时间", value: Fmt.time(result.updatedAt))
            }

            if let error = result?.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - 全天合计

    private var summarySection: some View {
        Section("全天合计") {
            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text("营业额(元)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(moneyText)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(result == nil || result?.error != nil ? Color.secondary : Color.primary)
                }

                HStack(spacing: 0) {
                    MetricBlock(title: "油量(升)", value: volumeText)
                    Divider().frame(height: 34)
                    MetricBlock(title: "交易笔数", value: countText)
                }

                Text("营业日期 \(dateText)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

    private var moneyText: String { result.map { "¥" + Fmt.money($0.amount) } ?? "--" }
    private var volumeText: String { result.map { Fmt.volume($0.volume) } ?? "--" }
    private var countText: String { result.map { "\($0.count)" } ?? "--" }

    // MARK: - 各班次明细

    private var shiftSection: some View {
        Section("各班次明细") {
            if let shifts = result?.shifts, !shifts.isEmpty {
                ForEach(shifts) { shift in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("第 \(shift.shift) 班")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("¥" + Fmt.money(shift.amount))
                                .font(.subheadline)
                                .monospacedDigit()
                        }

                        HStack(spacing: 10) {
                            Text("\(Fmt.volume(shift.volume)) 升 · \(shift.count) 笔")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            StatusBadge(timing: shift.timing, compact: true)
                        }

                        if !shift.period.isEmpty {
                            Text("时段 " + shift.period)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 3)
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
                Text(placeholder("当日暂无交易记录"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 全天按油品（只显示升数）

    private var productSection: some View {
        Section {
            if let products = result?.products, !products.isEmpty {
                ForEach(products) { item in
                    HStack(spacing: 12) {
                        Text(item.name.isEmpty ? item.code : item.name)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text("\(Fmt.volume(item.volume)) 升")
                            .monospacedDigit()
                            .fontWeight(.medium)
                    }
                    .padding(.vertical, 3)
                }
            } else {
                Text(placeholder("当日暂无按油品汇总"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("全天按油品")
        } footer: {
            Text("按油品只统计升数。")
        }
    }

    // MARK: - 逐笔明细

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
                            Text(row.tradeTime)
                                .font(.caption)
                                .monospacedDigit()
                            Text("第 \(row.shift) 班")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("¥" + Fmt.money(row.amount))
                                .font(.caption)
                                .monospacedDigit()
                        }
                        HStack {
                            Text("\(row.productName) · \(row.fipID)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Fmt.volume(row.volume)) 升 · \(row.paidState)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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

    // MARK: - 逻辑

    /// 未查询 / 出错 / 确实没有数据，三种情况的提示文案
    private func placeholder(_ noneText: String) -> String {
        guard result != nil else { return "尚未查询，请先选好营业日期并点「查询当日数据」" }
        if result?.error != nil { return "读取失败，请重新查询" }
        return noneText
    }

    private func loadAll() async {
        guard !isLoading else { return }
        isLoading = true
        trades = []
        Diag.log("【详情】开始查询 \(station.name) \(dateText)")
        result = await RevenueService.refresh(station, date: dateText)
        isLoading = false
    }

    private func loadTrades(shift: Int?) async {
        isLoadingTrades = true
        do {
            let rows = try await DatabaseService.fetchTrades(station, date: dateText, shift: shift)
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
            let url = try CSVExporter.writeTrades(trades, stationName: station.name, date: dateText, shift: nil)
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
