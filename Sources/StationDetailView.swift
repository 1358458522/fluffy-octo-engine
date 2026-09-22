import SwiftUI
import UIKit

/// 站点详情：单站取数。
/// - 本页自带「营业日期」选择，可查任意一天；
/// - 不做自动取数、不做下拉刷新：任何云库连接都必须由用户点按钮手动触发，串行执行，避免闪退；
/// - 全天按油品只统计升数，不再展示按支付方式；
/// - 逐笔明细不再限制笔数（单日一次性全量；区间按页加载，避免内存与卡顿）；
/// - 可选「按营业日区间」统计：合计营业额、油量、交易笔数（起止两端含当日）。
struct StationDetailView: View {
    let station: Station

    /// 区间明细每页笔数（分页加载用）
    private let rangePageSize = 200
    /// 界面最多渲染多少笔明细（仅渲染上限，不影响加载与导出的全量数据）
    private let tradeDisplayLimit = 200

    @State private var date: Date
    @State private var result: StationResult?
    @State private var trades: [TradeRow] = []
    @State private var isLoading = false
    @State private var isLoadingTrades = false
    @State private var showShare = false
    @State private var exportItems: [Any] = []
    @State private var alert: AlertPayload?

    // 营业日区间
    @State private var useRange = false
    @State private var rangeStart: Date
    @State private var rangeEnd: Date
    @State private var rangeResult: DateRangeResult?

    // 当前已加载明细的来源（导出与翻页使用）
    @State private var tradesFrom = ""
    @State private var tradesTo: String?
    @State private var tradesShift: Int?
    @State private var tradesTotal = 0
    @State private var tradesHasMore = false

    init(station: Station) {
        self.station = station
        let now = Date()
        _date = State(initialValue: now)
        _rangeStart = State(initialValue: Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now)
        _rangeEnd = State(initialValue: now)
    }

    /// 当前所选营业日期（yyyy-MM-dd）
    private var dateText: String { Fmt.dateFormatter.string(from: date) }

    /// 已查到的结果是否还是当前所选日期的
    private var isStale: Bool {
        guard let result else { return false }
        return result.date != dateText
    }

    /// 区间起止（自动按先后排序，用户选反也能正常查询）
    private var rangeFromText: String {
        let a = Fmt.dateFormatter.string(from: rangeStart)
        let b = Fmt.dateFormatter.string(from: rangeEnd)
        return min(a, b)
    }

    private var rangeToText: String {
        let a = Fmt.dateFormatter.string(from: rangeStart)
        let b = Fmt.dateFormatter.string(from: rangeEnd)
        return max(a, b)
    }

    /// 已查区间是否与当前所选的起止一致
    private var isRangeStale: Bool {
        guard let rangeResult else { return false }
        return rangeResult.from != rangeFromText || rangeResult.to != rangeToText
    }

    var body: some View {
        List {
            querySection
            if useRange {
                rangeSummarySection
                rangeDailySection
                rangeProductSection
            } else {
                overviewSection
                summarySection
                shiftSection
                productSection
            }
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
                .disabled(useRange ? rangeResult == nil : result == nil)
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
            Toggle(isOn: $useRange) {
                Label("按营业日区间统计", systemImage: "calendar.badge.clock")
            }

            if useRange {
                HStack {
                    Label("开始日期", systemImage: "calendar")
                    Spacer()
                    DatePicker("开始日期", selection: $rangeStart, displayedComponents: .date)
                        .labelsHidden()
                }

                HStack {
                    Label("结束日期", systemImage: "calendar")
                    Spacer()
                    DatePicker("结束日期", selection: $rangeEnd, displayedComponents: .date)
                        .labelsHidden()
                }

                HStack(spacing: 8) {
                    quickRangeButton("近 7 天", days: 6)
                    quickRangeButton("近 30 天", days: 29)
                    quickRangeButton("本月", monthStart: true)
                }

                Text("将统计 \(rangeFromText) ~ \(rangeToText)（含起止两端）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
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
            }

            Button {
                Task { await loadAll() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(queryButtonTitle)
                    Spacer()
                    if isLoading { ProgressView() }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading)

            if !useRange && isStale {
                Label("当前结果是 \(result?.date ?? "") 的，日期已改为 \(dateText)，请重新查询",
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if useRange && isRangeStale {
                Label("当前结果是 \(rangeResult?.from ?? "") ~ \(rangeResult?.to ?? "") 的，区间已改动，请重新查询",
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

    private var queryButtonTitle: String {
        if useRange {
            return rangeResult == nil ? "查询区间数据" : "重新查询区间数据"
        }
        return result == nil ? "查询当日数据" : "重新查询当日数据"
    }

    /// 区间快捷按钮：起点按天数或本月 1 日，终点固定为今天
    private func quickRangeButton(_ title: String, days: Int? = nil, monthStart: Bool = false) -> some View {
        let calendar = Calendar.current
        let now = Date()
        let target: Date
        if monthStart {
            let comps = calendar.dateComponents([.year, .month], from: now)
            target = calendar.date(from: comps) ?? now
        } else {
            target = calendar.date(byAdding: .day, value: -(days ?? 0), to: now) ?? now
        }
        let targetText = Fmt.dateFormatter.string(from: target)
        let todayText = Fmt.dateFormatter.string(from: now)
        let selected = (targetText == rangeFromText && todayText == rangeToText)
        return Button {
            rangeStart = target
            rangeEnd = now
        } label: {
            Text(title)
                .font(.footnote)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(selected ? Color.accentColor : Color.secondary)
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

    // MARK: - 区间合计

    private var rangeSummarySection: some View {
        Section {
            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text("营业额(元)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(rangeMoneyText)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(rangeResult == nil || rangeResult?.error != nil ? Color.secondary : Color.primary)
                }

                HStack(spacing: 0) {
                    MetricBlock(title: "油量(升)", value: rangeVolumeText)
                    Divider().frame(height: 34)
                    MetricBlock(title: "交易笔数", value: rangeCountText)
                }

                Text("营业日期 \(rangeFromText) ~ \(rangeToText)（含起止两端，有数据 \(rangeDaysText) 天）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

                if let first = rangeResult?.firstTime, let last = rangeResult?.lastTime {
                    Text("首笔 \(first) · 末笔 \(last)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            if let error = rangeResult?.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("区间合计")
        } footer: {
            Text("口径与单日一致：合计取该区间全部班次交易，按油品只统计升数。")
        }
    }

    private var rangeMoneyText: String { rangeResult.map { "¥" + Fmt.money($0.amount) } ?? "--" }
    private var rangeVolumeText: String { rangeResult.map { Fmt.volume($0.volume) } ?? "--" }
    private var rangeCountText: String { rangeResult.map { "\($0.count)" } ?? "--" }
    private var rangeDaysText: String { rangeResult.map { "\($0.days)" } ?? "--" }

    // MARK: - 区间按营业日

    private var rangeDailySection: some View {
        Section {
            if let days = rangeResult?.daily, !days.isEmpty {
                ForEach(days) { day in
                    HStack(spacing: 12) {
                        Text(day.date)
                            .font(.subheadline)
                            .monospacedDigit()

                        Spacer(minLength: 8)

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("¥" + Fmt.money(day.amount))
                                .font(.subheadline)
                                .monospacedDigit()
                            Text("\(Fmt.volume(day.volume)) 升 · \(day.count) 笔")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }

                Button {
                    exportRangeSummary()
                } label: {
                    Label("导出区间汇总为 CSV", systemImage: "square.and.arrow.up")
                }
            } else {
                Text(rangePlaceholder("该区间暂无交易记录"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("按营业日")
        } footer: {
            Text("按营业日拆分，便于逐日核对营业额。")
        }
    }

    // MARK: - 区间按油品（只显示升数）

    private var rangeProductSection: some View {
        Section {
            if let products = rangeResult?.products, !products.isEmpty {
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
                Text(rangePlaceholder("该区间暂无按油品汇总"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("区间按油品")
        } footer: {
            Text("按油品只统计升数。")
        }
    }

    // MARK: - 逐笔明细（不限笔数）

    private var tradesSection: some View {
        Section {
            if useRange {
                Button {
                    Task { await loadRangeTrades() }
                } label: {
                    HStack {
                        Label("加载区间全部明细（每页 \(rangePageSize) 笔）", systemImage: "doc.text.magnifyingglass")
                        Spacer()
                        if isLoadingTrades { ProgressView() }
                    }
                }
                .disabled(isLoadingTrades)

                if !trades.isEmpty && tradesHasMore {
                    Button {
                        Task { await loadRangeTrades(nextPage: true) }
                    } label: {
                        Label("继续加载后 \(rangePageSize) 笔（已 \(trades.count) / \(tradesTotal) 笔）",
                              systemImage: "arrow.down.circle")
                    }
                    .disabled(isLoadingTrades)
                }
            } else {
                Button {
                    Task { await loadTrades(shift: nil) }
                } label: {
                    HStack {
                        Label("加载当日全部明细（不限笔数）", systemImage: "doc.text.magnifyingglass")
                        Spacer()
                        if isLoadingTrades { ProgressView() }
                    }
                }
                .disabled(isLoadingTrades)
            }

            if !trades.isEmpty {
                Button {
                    exportTrades()
                } label: {
                    Label("导出这 \(trades.count) 笔为 CSV", systemImage: "square.and.arrow.up")
                }

                ForEach(trades.prefix(tradeDisplayLimit)) { row in
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

                if trades.count > tradeDisplayLimit {
                    Text("界面只渲染前 \(tradeDisplayLimit) 笔，导出可拿到已加载的全部 \(trades.count) 笔")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if useRange && tradesHasMore {
                    Text("已加载 \(trades.count) / \(tradesTotal) 笔，可继续加载")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("逐笔明细")
        } footer: {
            Text(useRange
                 ? "区间明细按每页 \(rangePageSize) 笔分页加载，逐笔不截断，避免一次性拉取造成卡顿。"
                 : "单日明细已取消 500 笔上限，点一次即加载当日全部交易。")
        }
    }

    // MARK: - 逻辑

    /// 未查询 / 出错 / 确实没有数据，三种情况的提示文案
    private func placeholder(_ noneText: String) -> String {
        guard result != nil else { return "尚未查询，请先选好营业日期并点「查询当日数据」" }
        if result?.error != nil { return "读取失败，请重新查询" }
        return noneText
    }

    private func rangePlaceholder(_ noneText: String) -> String {
        guard rangeResult != nil else { return "尚未查询，请先选好起止日期并点「查询区间数据」" }
        if rangeResult?.error != nil { return "读取失败，请重新查询" }
        return noneText
    }

    private func loadAll() async {
        guard !isLoading else { return }
        isLoading = true
        trades = []
        tradesTotal = 0
        tradesHasMore = false

        if useRange {
            rangeResult = nil
            Diag.log("【详情】开始查询区间 \(station.name) \(rangeFromText) ~ \(rangeToText)")
            rangeResult = await RevenueService.refreshRange(station, from: rangeFromText, to: rangeToText)
        } else {
            Diag.log("【详情】开始查询 \(station.name) \(dateText)")
            result = await RevenueService.refresh(station, date: dateText)
        }

        isLoading = false
    }

    /// 单日逐笔明细：一次性全量加载（已取消 500 笔上限）
    private func loadTrades(shift: Int?) async {
        guard !isLoadingTrades else { return }
        isLoadingTrades = true
        do {
            let page = try await DatabaseService.fetchTrades(station, from: dateText, shift: shift)
            trades = page.rows
            tradesTotal = page.total
            tradesHasMore = page.hasMore
            tradesFrom = dateText
            tradesTo = nil
            tradesShift = shift
            if page.rows.isEmpty {
                alert = AlertPayload(title: "没有数据", message: "该范围内没有查到交易记录。")
            }
        } catch {
            alert = AlertPayload(title: "读取失败", message: "\(error)")
        }
        isLoadingTrades = false
    }

    /// 区间逐笔明细：按页加载（默认每页 \(rangePageSize) 笔），避免一次性拉爆内存
    private func loadRangeTrades(nextPage: Bool = false) async {
        guard !isLoadingTrades else { return }
        isLoadingTrades = true
        do {
            let offset = nextPage ? trades.count : 0
            let page = try await DatabaseService.fetchTrades(
                station,
                from: rangeFromText,
                to: rangeToText,
                offset: offset,
                pageSize: rangePageSize
            )
            trades = nextPage ? (trades + page.rows) : page.rows
            tradesTotal = page.total
            tradesHasMore = offset + page.rows.count < page.total
            tradesFrom = rangeFromText
            tradesTo = rangeToText
            tradesShift = nil
            if page.rows.isEmpty {
                alert = AlertPayload(title: "没有数据", message: "该区间没有查到交易记录。")
            }
        } catch {
            alert = AlertPayload(title: "读取失败", message: "\(error)")
        }
        isLoadingTrades = false
    }

    private func exportTrades() {
        let from = tradesFrom.isEmpty ? dateText : tradesFrom
        let label: String?
        if let to = tradesTo {
            label = "\(from)_\(to)"
        } else if let shift = tradesShift {
            label = "第\(shift)班"
        } else {
            label = nil
        }
        do {
            let url = try CSVExporter.writeTrades(
                trades,
                stationName: station.name,
                date: from,
                shift: tradesShift,
                label: label
            )
            exportItems = [url]
            showShare = true
        } catch {
            alert = AlertPayload(title: "导出失败", message: error.localizedDescription)
        }
    }

    private func exportRangeSummary() {
        guard let rangeResult else { return }
        do {
            let url = try CSVExporter.writeRange(rangeResult, stationName: station.name)
            exportItems = [url]
            showShare = true
        } catch {
            alert = AlertPayload(title: "导出失败", message: error.localizedDescription)
        }
    }

    /// 复制与电脑端详情窗口一致的文本
    private func copyAll() {
        if useRange {
            guard let rangeResult else { return }
            UIPasteboard.general.string = DayReportText.makeRange(result: rangeResult, station: station)
            alert = AlertPayload(title: "已复制", message: "区间汇总已复制到剪贴板，可直接粘贴到微信或备忘录。")
            return
        }
        guard let result else { return }
        UIPasteboard.general.string = DayReportText.make(result: result, station: station)
        alert = AlertPayload(title: "已复制", message: "详情已复制到剪贴板，可直接粘贴到微信或备忘录。")
    }
}
