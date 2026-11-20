import SwiftUI

/// 加油记录对比：按「油品 + 枪号」对比「一个营业日」与「一个对比区间」的交易金额，并给出金额占比。
/// 口径：交易金额 = 应收 FDueAmount（老库缺列时回退 FTradeAmount）；枪号 = FFipID。
struct NozzleCompareView: View {
    let station: Station

    @State private var curDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var baseStart: Date = Calendar.current.date(
        byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: Date())
    ) ?? Date()
    @State private var baseEnd: Date = Calendar.current.date(
        byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date())
    ) ?? Date()
    @State private var rows: [NozzleCompare] = []
    @State private var isLoading = false
    @State private var errorText: String?

    private var curText: String { Fmt.dateFormatter.string(from: curDate) }
    private var baseStartText: String { Fmt.dateFormatter.string(from: baseStart) }
    private var baseEndText: String { Fmt.dateFormatter.string(from: baseEnd) }

    /// 营业日变化时，对比区间自动整体平移为「该日之前 7 天 ~ 前一天」
    private var curBinding: Binding<Date> {
        Binding(
            get: { curDate },
            set: { newValue in
                curDate = newValue
                let cal = Calendar.current
                baseEnd = cal.date(byAdding: .day, value: -1, to: newValue) ?? newValue
                baseStart = cal.date(byAdding: .day, value: -7, to: newValue) ?? newValue
            }
        )
    }

    /// 区间开始不得晚于结束
    private var baseStartBinding: Binding<Date> {
        Binding(
            get: { baseStart },
            set: { newValue in
                baseStart = newValue
                if baseEnd < newValue { baseEnd = newValue }
            }
        )
    }

    /// 区间结束不得早于开始
    private var baseEndBinding: Binding<Date> {
        Binding(
            get: { baseEnd },
            set: { newValue in
                baseEnd = newValue
                if baseStart > newValue { baseStart = newValue }
            }
        )
    }

    /// 枪号数值（非纯数字排在最后）
    private func nozzleValue(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return Int(trimmed) ?? Int.max
    }

    /// 先按油品，再按枪号数值升序（纯数字比较，不按字符串排序）
    private var sortedRows: [NozzleCompare] {
        rows.sorted { lhs, rhs in
            if lhs.productCode != rhs.productCode { return lhs.productCode < rhs.productCode }
            let l = nozzleValue(lhs.fipID), r = nozzleValue(rhs.fipID)
            if l != r { return l < r }
            return lhs.fipID < rhs.fipID
        }
    }

    private var totalAmount: Double { rows.reduce(0) { $0 + $1.amount } }
    private var totalAmount2: Double { rows.reduce(0) { $0 + $1.amount2 } }

    var body: some View {
        List {
            querySection
            resultSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("加油记录对比")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - 查询条件

    private var querySection: some View {
        Group {
            Section {
                DatePicker("日期", selection: curBinding, displayedComponents: .date)
            } header: {
                Text("营业日")
            }

            Section {
                DatePicker("开始", selection: baseStartBinding, displayedComponents: .date)
                DatePicker("结束", selection: baseEndBinding, displayedComponents: .date)
            } header: {
                Text("对比区间")
            } footer: {
                Text("当期 \(curText)　对比 \(baseStartText) ~ \(baseEndText)")
                    .font(.caption2)
            }
        }
    }

    // MARK: - 结果

    private var resultSection: some View {
        Section {
            if isLoading && rows.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 8)
            } else if let errorText {
                EmptyHint(icon: "exclamationmark.triangle", title: "查询失败", message: errorText)
            } else if rows.isEmpty {
                EmptyHint(
                    icon: "chart.bar.doc.horizontal",
                    title: "暂无对比数据",
                    message: "所选营业日与对比区间没有加油记录"
                )
            } else {
                headerRow
                ForEach(sortedRows) { row in
                    valueRow(row)
                }
                totalRow
            }
        } header: {
            HStack {
                Text("对比明细")
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("查询")
                    }
                }
                .font(.caption)
                .disabled(isLoading)
            }
        } footer: {
            Text("交易金额 = 当期该营业日合计；交易金额2 = 对比区间合计。占比 = 当期 ÷ 区间合计 × 100%，区间为 0 时显示「—」。")
                .font(.caption2)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text("油品").frame(width: 56, alignment: .leading)
            Text("枪号").frame(width: 36, alignment: .trailing)
            Text("交易金额").frame(maxWidth: .infinity, alignment: .trailing)
            Text("交易金额2").frame(maxWidth: .infinity, alignment: .trailing)
            Text("占比").frame(width: 58, alignment: .trailing)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func valueRow(_ row: NozzleCompare) -> some View {
        HStack(spacing: 6) {
            Text(row.productLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 56, alignment: .leading)
            Text(row.nozzleLabel)
                .frame(width: 36, alignment: .trailing)
            Text(Fmt.money(row.amount))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(Fmt.money(row.amount2))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            ratioText(row.amountRatio)
                .frame(width: 58, alignment: .trailing)
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
    }

    private var totalRow: some View {
        HStack(spacing: 6) {
            Text("合计")
                .fontWeight(.semibold)
                .frame(width: 56, alignment: .leading)
            Text("—")
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(Fmt.money(totalAmount))
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(Fmt.money(totalAmount2))
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            ratioText(NozzleCompare.ratio(totalAmount, totalAmount2), bold: true)
                .frame(width: 58, alignment: .trailing)
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
    }

    private func ratioText(_ value: Double?, bold: Bool = false) -> some View {
        let text = value.map { String(format: "%.2f%%", $0) } ?? "—"
        let color: Color
        if let value {
            color = value > 100 ? .green : (value < 100 ? .orange : .primary)
        } else {
            color = .secondary
        }
        return Text(text)
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    // MARK: - 数据

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let result = try await DatabaseService.fetchNozzleCompare(
                station,
                from: curText,
                to: curText,
                from2: baseStartText,
                to2: baseEndText
            )
            rows = result
        } catch {
            rows = []
            errorText = error.localizedDescription
        }
    }
}
