import SwiftUI

/// 加油记录对比：单个营业日内，按「油品 + 枪号」对比两类金额并给出占比。
/// 交易金额 = 当日 FExFlag = 1 的子集合计；交易金额2 = 当日全量合计。枪号 = FFipID。
struct NozzleCompareView: View {
    let station: Station

    @State private var queryDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var rows: [NozzleCompare] = []
    @State private var isLoading = false
    @State private var errorText: String?

    private var dateText: String { Fmt.dateFormatter.string(from: queryDate) }

    /// 枪号数值（非纯数字排在最后）
    private func nozzleValue(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return Int(trimmed) ?? Int.max
    }

    /// 枪号数值升序为主键，同枪号再按油品升序
    private var sortedRows: [NozzleCompare] {
        rows.sorted { lhs, rhs in
            let l = nozzleValue(lhs.fipID), r = nozzleValue(rhs.fipID)
            if l != r { return l < r }
            if lhs.productCode != rhs.productCode { return lhs.productCode < rhs.productCode }
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
        Section {
            DatePicker("营业日", selection: $queryDate, displayedComponents: .date)
        } footer: {
            Text("当前查看：\(dateText)")
                .font(.caption2)
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
                    message: "所选营业日没有加油记录"
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
            Text("交易金额 = 当日标志为 1 的交易合计；交易金额2 = 当日合计。占比 = 交易金额 ÷ 交易金额2 × 100%，为 0 时显示「—」。")
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
            rows = try await DatabaseService.fetchNozzleDay(station, date: dateText)
        } catch {
            rows = []
            errorText = error.localizedDescription
        }
    }
}
