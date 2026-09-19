import SwiftUI
import UIKit

struct AlertPayload: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 首页

/// 取数策略（自签真机稳定版）：
/// - 启动不自动刷新、切换营业日期不自动刷新，一切由用户手动触发；
/// - 查询只针对勾选的站点，逐站串行执行，任何时刻最多一个云库连接；
/// - 单站详情点进去只查该站，不做任何批量。
struct HomeView: View {
    @EnvironmentObject private var store: ConfigStore

    @State private var results: [StationResult] = []
    @State private var selected: Set<UUID> = []
    @State private var isQuerying = false
    @State private var progressText: String?
    @State private var date = Date()
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @State private var showShare = false
    @State private var exportItems: [Any] = []
    @State private var alert: AlertPayload?
    @State private var dateDirty = false

    private var dateText: String { Fmt.dateFormatter.string(from: date) }

    /// 只认「当前营业日期」的结果，避免切换日期后误展示旧数据
    private var currentResults: [StationResult] { results.filter { $0.date == dateText } }
    private var totalCount: Int { currentResults.reduce(0) { $0 + $1.count } }
    private var failedCount: Int { currentResults.filter { $0.error != nil }.count }
    private var closedCount: Int { currentResults.filter { $0.error == nil && $0.timing == .closed }.count }

    var body: some View {
        NavigationStack {
            List {
                if Diag.hasPreviousCrash() { crashSection }
                dateSection
                stationsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("天天油报")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showDiagnostics = true } label: {
                        Image(systemName: "stethoscope")
                    }
                    Button { exportSummary() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(currentResults.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .refreshable {
                guard !selected.isEmpty else { return }
                await querySelected()
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .sheet(isPresented: $showShare) { ShareSheet(items: exportItems) }
            .alert(item: $alert) { payload in
                Alert(title: Text(payload.title), message: Text(payload.message), dismissButton: .default(Text("好")))
            }
        }
    }

    // MARK: 子视图

    /// 上次闪退提示（有崩溃报告时出现）
    private var crashSection: some View {
        Section {
            Button {
                showDiagnostics = true
            } label: {
                Label("上次运行发生过闪退，点此查看崩溃报告与运行日志", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    /// 营业日期 + 汇总计数（不展示总营业额，各站营业额在站点行内分别展示）
    private var dateSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("营业日期").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                        .onChange(of: date) { _ in
                            // 不自动取数：改日期只标记待查询，由用户点按钮逐站查
                            dateDirty = true
                        }
                }

                HStack(spacing: 14) {
                    Label("\(currentResults.count) 站已查", systemImage: "building.2")
                    Label("\(totalCount) 笔", systemImage: "number")
                    if failedCount > 0 {
                        Label("\(failedCount) 站失败", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if !currentResults.isEmpty {
                    HStack(spacing: 14) {
                        Label("\(closedCount) 站已交班", systemImage: "checkmark.seal")
                        Label("\(currentResults.count - closedCount) 站未交班", systemImage: "clock.badge.exclamationmark")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Label(ShiftTiming.closed.rawValue, systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(ShiftTiming.closed.displayColor)
                    Label(ShiftTiming.running.rawValue, systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(ShiftTiming.running.displayColor)
                    Spacer()
                    if let latest = currentResults.map({ $0.updatedAt }).max() {
                        Text("更新于 \(Fmt.time(latest))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if dateDirty && !selected.isEmpty {
                    Text("已切换到 \(dateText)，点底部「查询选中站点」重新取数")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var stationsSection: some View {
        Section {
            if store.stations.isEmpty {
                Text("还没有站点。点左上角齿轮 → 添加站点，或从剪贴板/文件批量导入配置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.stations) { station in
                    HStack(spacing: 10) {
                        Button {
                            toggle(station)
                        } label: {
                            Image(systemName: selected.contains(station.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selected.contains(station.id) ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            StationDetailView(station: station, initial: result(for: station), date: dateText)
                        } label: {
                            StationRow(station: station, result: result(for: station))
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("站点（\(selected.count) 已选）")
                Spacer()
                Button(allSelected ? "取消全选" : "全选") {
                    selected = allSelected ? [] : Set(store.stations.map(\.id))
                }
                .font(.caption)
                .disabled(store.stations.isEmpty)
            }
        } footer: {
            Text("勾选站点后点底部按钮逐个查询（串行，一次只连一个云库）；点站点名称进入单站详情，只查该站。")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if let progressText {
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await querySelected() }
            } label: {
                HStack(spacing: 8) {
                    if isQuerying { ProgressView().tint(.white) }
                    Text(isQuerying ? "正在查询…" : "查询选中站点（\(selected.count)）")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isQuerying || selected.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: 逻辑

    private var allSelected: Bool {
        !store.stations.isEmpty && selected.count == store.stations.count
    }

    private func toggle(_ station: Station) {
        if selected.contains(station.id) {
            selected.remove(station.id)
        } else {
            selected.insert(station.id)
        }
    }

    private func result(for station: Station) -> StationResult? {
        results.first { $0.id == station.id && $0.date == dateText }
    }

    /// 逐站串行查询勾选的站点
    private func querySelected() async {
        guard !isQuerying else { return }
        let targets = store.stations.filter { selected.contains($0.id) }
        guard !targets.isEmpty else {
            alert = AlertPayload(title: "先勾选站点", message: "在站点列表左侧勾选一个或多个站点，再点查询。")
            return
        }

        isQuerying = true
        let day = dateText
        Diag.log("【首页】开始查询 \(targets.count) 站（串行）")

        let fresh = await RevenueService.refreshSerial(targets, date: day) { done, total, name in
            progressText = "正在查询 \(done + 1)/\(total)：\(name)"
        }

        merge(fresh)
        progressText = nil
        isQuerying = false
        dateDirty = false
    }

    private func merge(_ fresh: [StationResult]) {
        let order = Dictionary(uniqueKeysWithValues: store.stations.enumerated().map { ($1.id, $0) })
        for item in fresh {
            if let idx = results.firstIndex(where: { $0.id == item.id }) {
                results[idx] = item
            } else {
                results.append(item)
            }
        }
        results.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }

    private func exportSummary() {
        do {
            let url = try CSVExporter.writeSummary(currentResults, date: dateText)
            exportItems = [url]
            showShare = true
        } catch {
            alert = AlertPayload(title: "导出失败", message: error.localizedDescription)
        }
    }
}

// MARK: - 站点行（逐站展示各自营业额与交班状态）

struct StationRow: View {
    let station: Station
    let result: StationResult?

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(station.name)
                if let result, let error = result.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let result {
                    Text("\(result.count) 笔 · \(Fmt.volume(result.volume)) 升")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("未查询")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(result == nil ? "--" : "¥" + Fmt.money(result?.amount ?? 0))
                    .font(.callout)
                    .monospacedDigit()
                if let result, result.error == nil {
                    Text(result.timing.rawValue)
                        .font(.caption2)
                        .foregroundStyle(result.timing.displayColor)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var indicatorColor: Color {
        guard let result else { return .gray }
        if result.error != nil { return .red }
        return result.timing.displayColor
    }
}
