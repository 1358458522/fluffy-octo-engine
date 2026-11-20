import SwiftUI

/// 加油记录对比：按「油品 + 枪号」对比两组交易营业日的
/// 交易金额 / 实收金额 / 交易升数 / 次数，以及金额、升数、次数占比。
///
/// - 两组区间都由用户自行选择，不做写死规则；对比期默认取「当期前一天」，
///   并给出「等长前移 / 上周同期 / 上月同日」快捷方式；
/// - 数据全部实时取自本站云库 moms（不读电脑端任何文件）；
/// - 只连本站一个云库、串行执行，与详情页其它查询一致。
struct NozzleCompareView: View {
    let station: Station

    @State private var curStart: Date
    @State private var curEnd: Date
    @State private var baseStart: Date
    @State private var baseEnd: Date

    @State private var rows: [NozzleCompare] = []
    /// 已取结果对应的区间标记，用于提示「区间已改、需重新查询」
    @State private var resultKey = ""
    @State private var isLoading = false
    @State private var errorText: String?

    /// 表格列（列名 + 宽度），横向滚动展示
    private let columns: [(title: String, width: CGFloat)] = [
        ("油品", 62),
        ("枪号", 44),
        ("交易金额", 84),
        ("实收金额", 84),
        ("交易升数", 84),
        ("次数", 48),
        ("交易金额2", 88),
        ("实收金额2", 88),
        ("交易升数2", 88),
        ("次数2", 48),
        ("金额占比", 76),
        ("升数占比", 76),
        ("次数占比", 76)
    ]

    init(station: Station) {
        self.station = station
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        _curStart = State(initialValue: today)
        _curEnd = State(initialValue: today)
        _baseStart = State(initialValue: yesterday)
        _baseEnd = State(initialValue: yesterday)
    }

    // MARK: - 区间文本

    private var curFromText: String {
        let a = Fmt.dateFormatter.string(from: curStart)
        let b = Fmt.dateFormatter.string(from: curEnd)
        return min(a, b)
    }

    private var curToText: String {
        let a = Fmt.dateFormatter.string(from: curStart)
        let b = Fmt.dateFormatter.string(from: curEnd)
        return max(a, b)
    }

    private var baseFromText: String {
        let a = Fmt.dateFormatter.string(from: baseStart)
        let b = Fmt.dateFormatter.string(from: baseEnd)
        return min(a, b)
    }

    private var baseToText: String {
        let a = Fmt.dateFormatter.string(from: baseStart)
        let b = Fmt.dateFormatter.string(from: baseEnd)
        return max(a, b)
    }

    private var currentKey: String {
        "\(curFromText)~\(curToText)|\(baseFromText)~\(baseToText)"
    }

    private var isStale: Bool {
        !rows.isEmpty && resultKey != currentKey
    }

    /// 当期区间天数（含两端），用于「等长前移」
    private var currentDays: Int {
        let calendar = Calendar.current
        let a = Fmt.parseDay(curFromText) ?? Date()
        let b = Fmt.parseDay(curToText) ?? Date()
        let days = calendar.dateComponents([.day], from: a, to: b).day ?? 0
        return max(days, 0) + 1
    }

    var body: some View {
        List {
            currentSection
            baseSection
            querySection
            resultSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("加油记录对比")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    if isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(isLoading)
                .accessibilityLabel("重新查询")
            }
        }
    }

    // MARK: - 当期区间

    private var currentSection: some View {
        Section {
            HStack {
                Label("开始营业日", systemImage: "calendar")
                Spacer()
                DatePicker("开始营业日", selection: $curStart, displayedComponents: .date)
                    .labelsHidden()
            }
            HStack {
                Label("结束营业日", systemImage: "calendar")
                Spacer()
                DatePicker("结束营业日", selection: $curEnd, displayedComponents: .date)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                curQuickButton("今天", start: day(0), end: day(0))
                curQuickButton("昨天", start: day(-1), end: day(-1))
                curQuickButton("近 7 天", start: day(-6), end: day(0))
            }
        } header: {
            Text("当期（交易营业日）")
        } footer: {
            Text("统计 \(curFromText) ~ \(curToText)，含起止两天。")
        }
    }

    // MARK: - 对比期区间

    private var baseSection: some View {
        Section {
            HStack {
                Label("开始营业日", systemImage: "calendar")
                Spacer()
                DatePicker("开始营业日", selection: $baseStart, displayedComponents: .date)
                    .labelsHidden()
            }
            HStack {
                Label("结束营业日", systemImage: "calendar")
                Spacer()
                DatePicker("结束营业日", selection: $baseEnd, displayedComponents: .date)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                baseQuickButton("前一天", start: day(-1), end: day(-1))
                baseQuickButton("等长前移", start: shiftCur(-currentDays), end: shiftCur(-1))
                baseQuickButton("上月同日", start: monthSameDay(), end: monthSameDay())
            }
        } header: {
            Text("对比期（交易营业日）")
        } footer: {
            Text("对比期可任意调整：默认「当期前一天」，也可用「等长前移」（与当期同样天数、紧邻往前）或「上月同日」。占比 = 当期 ÷ 对比期 × 100%。")
        }
    }

    // MARK: - 查询

    private var querySection: some View {
        Section {
            Button {
                Task { await load() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                    Text(rows.isEmpty ? "查询对比数据" : "重新查询对比数据")
                    Spacer()
                    if isLoading { ProgressView() }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading)

            if isStale {
                Label("当前结果是上一次区间（\(resultKey.replacingOccurrences(of: "|", with: " 对比 "))）的，区间已改动，请重新查询",
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let errorText {
                Label(errorText, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("查询")
        } footer: {
            Text("数据实时取自本站云库 moms，两组区间各自独立查询后按油品 + 枪号合并。")
        }
    }

    // MARK: - 结果

    private var resultSection: some View {
        Section {
            if isLoading && rows.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在从云库取数…").font(.footnote).foregroundStyle(.secondary)
                }
            } else if rows.isEmpty {
                EmptyHint(icon: "tablecells",
                          title: "暂无对比数据",
                          message: "选好两组交易营业日后点「查询对比数据」。")
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        headerRow
                        Divider()
                        ForEach(rows) { row in
                            valueRow(row)
                            Divider()
                        }
                        totalRow
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("对比明细（按油品 + 枪号）")
        } footer: {
            Text("交易金额 = 应收金额 FDueAmount、实收金额 = 成交金额 FTradeAmount、交易升数 = 应收升数 FDueVolume，枪号取 FFipID（老库缺应收列时两者均回退 FTradeAmount / FTradeVolume）；带「2」为对比期数据。对比期为 0 时占比显示「—」。")
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(columns.enumerated()), id: \.offset) { item in
                Text(item.element.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: item.element.width, alignment: .trailing)
            }
        }
        .padding(.vertical, 6)
    }

    private func valueRow(_ row: NozzleCompare) -> some View {
        HStack(spacing: 8) {
            Text(row.productLabel)
                .font(.caption)
                .lineLimit(1)
                .frame(width: columns[0].width, alignment: .trailing)
            Text(row.nozzleLabel)
                .font(.caption)
                .monospacedDigit()
                .frame(width: columns[1].width, alignment: .trailing)
            cellText(Fmt.money(row.amount), width: columns[2].width)
            cellText(Fmt.money(row.paid), width: columns[3].width)
            cellText(Fmt.volume(row.volume), width: columns[4].width)
            cellText("\(row.count)", width: columns[5].width)
            cellText(Fmt.money(row.amount2), width: columns[6].width, secondary: true)
            cellText(Fmt.money(row.paid2), width: columns[7].width, secondary: true)
            cellText(Fmt.volume(row.volume2), width: columns[8].width, secondary: true)
            cellText("\(row.count2)", width: columns[9].width, secondary: true)
            ratioText(row.amountRatio, width: columns[10].width)
            ratioText(row.volumeRatio, width: columns[11].width)
            ratioText(row.countRatio, width: columns[12].width)
        }
        .padding(.vertical, 5)
    }

    private var totalRow: some View {
        let count = rows.reduce(0) { $0 + $1.count }
        let count2 = rows.reduce(0) { $0 + $1.count2 }
        let amount = rows.reduce(0) { $0 + $1.amount }
        let amount2 = rows.reduce(0) { $0 + $1.amount2 }
        let volume = rows.reduce(0) { $0 + $1.volume }
        let volume2 = rows.reduce(0) { $0 + $1.volume2 }
        let paid = rows.reduce(0) { $0 + $1.paid }
        let paid2 = rows.reduce(0) { $0 + $1.paid2 }
        return HStack(spacing: 8) {
            Text("合计")
                .font(.caption.weight(.semibold))
                .frame(width: columns[0].width + columns[1].width + 8, alignment: .trailing)
            cellText(Fmt.money(amount), width: columns[2].width, bold: true)
            cellText(Fmt.money(paid), width: columns[3].width, bold: true)
            cellText(Fmt.volume(volume), width: columns[4].width, bold: true)
            cellText("\(count)", width: columns[5].width, bold: true)
            cellText(Fmt.money(amount2), width: columns[6].width, bold: true, secondary: true)
            cellText(Fmt.money(paid2), width: columns[7].width, bold: true, secondary: true)
            cellText(Fmt.volume(volume2), width: columns[8].width, bold: true, secondary: true)
            cellText("\(count2)", width: columns[9].width, bold: true, secondary: true)
            ratioText(NozzleCompare.ratio(amount, amount2), width: columns[10].width, bold: true)
            ratioText(NozzleCompare.ratio(volume, volume2), width: columns[11].width, bold: true)
            ratioText(NozzleCompare.ratio(Double(count), Double(count2)), width: columns[12].width, bold: true)
        }
        .padding(.vertical, 6)
    }

    private func cellText(_ text: String, width: CGFloat, bold: Bool = false, secondary: Bool = false) -> some View {
        Text(text)
            .font(.caption)
            .monospacedDigit()
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(secondary ? Color.secondary : Color.primary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    private func ratioText(_ value: Double?, width: CGFloat, bold: Bool = false) -> some View {
        let text = value.map { String(format: "%.2f%%", $0) } ?? "—"
        let color: Color = {
            guard let value else { return .secondary }
            if value > 100 { return .green }
            if value < 100 { return .orange }
            return .primary
        }()
        return Text(text)
            .font(.caption)
            .monospacedDigit()
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    // MARK: - 快捷按钮与区间计算

    /// 当期区间快捷设置
    private func curQuickButton(_ title: String, start: Date, end: Date) -> some View {
        Button(title) {
            self.curStart = start
            self.curEnd = end
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// 对比期区间快捷设置
    private func baseQuickButton(_ title: String, start: Date, end: Date) -> some View {
        Button(title) {
            self.baseStart = start
            self.baseEnd = end
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    /// 当期区间整体前移 offset 天（相对当期起止）
    private func shiftCur(_ offset: Int) -> Date {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: curEnd)
        return calendar.date(byAdding: .day, value: offset, to: base) ?? base
    }

    /// 当期结束日的「上月同日」（无该日则取当月最后一天）
    private func monthSameDay() -> Date {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: curEnd)
        guard let lastMonth = calendar.date(byAdding: .month, value: -1, to: end) else { return end }
        let comps = calendar.dateComponents([.year, .month, .day], from: end)
        let lastDay = calendar.range(of: .day, in: .month, for: lastMonth)?.count ?? 28
        var target = calendar.dateComponents([.year, .month], from: lastMonth)
        target.day = min(comps.day ?? 1, lastDay)
        return calendar.date(from: target) ?? lastMonth
    }

    // MARK: - 取数

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        let key = currentKey
        do {
            let data = try await DatabaseService.fetchNozzleCompare(
                station,
                from: curFromText,
                to: curToText,
                from2: baseFromText,
                to2: baseToText
            )
            rows = data
            resultKey = key
            if data.isEmpty {
                errorText = "两组区间都没有取到交易，请确认营业日是否正确。"
            }
        } catch {
            rows = []
            resultKey = ""
            errorText = "取数失败：\(error.localizedDescription)"
        }
        isLoading = false
    }
}
