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

struct HomeView: View {
    @EnvironmentObject private var store: ConfigStore

    @State private var results: [StationResult] = []
    @State private var isRefreshing = false
    @State private var date = Date()
    @State private var showSettings = false
    @State private var showShare = false
    @State private var exportItems: [Any] = []
    @State private var alert: AlertPayload?

    private var dateText: String { Fmt.dateFormatter.string(from: date) }
    private var totalCount: Int { results.reduce(0) { $0 + $1.count } }
    private var failedCount: Int { results.filter { $0.error != nil }.count }
    private var closedCount: Int { results.filter { $0.error == nil && $0.timing == .closed }.count }

    var body: some View {
        NavigationStack {
            List {
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { exportSummary() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(results.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .refreshable { await refresh() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showShare) { ShareSheet(items: exportItems) }
            .alert(item: $alert) { payload in
                Alert(title: Text(payload.title), message: Text(payload.message), dismissButton: .default(Text("好")))
            }
        }
    }

    // MARK: 子视图

    /// 营业日期 + 汇总计数（不再展示总营业额，各站营业额在站点行内分别展示）
    private var dateSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("营业日期").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                        .onChange(of: date) { _ in
                            Task { await refresh() }
                        }
                }

                HStack(spacing: 14) {
                    Label("\(results.count) 站", systemImage: "building.2")
                    Label("\(totalCount) 笔", systemImage: "number")
                    if !results.isEmpty {
                        Label("\(closedCount) 站已交班", systemImage: "checkmark.seal")
                    }
                    if failedCount > 0 {
                        Label("\(failedCount) 站失败", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label(ShiftTiming.closed.rawValue, systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(ShiftTiming.closed.displayColor)
                    Label(ShiftTiming.running.rawValue, systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(ShiftTiming.running.displayColor)
                    Spacer()
                    if let latest = results.map({ $0.updatedAt }).max() {
                        Text("更新于 \(Fmt.time(latest))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var stationsSection: some View {
        Section("站点") {
            if store.stations.isEmpty {
                Text("还没有站点。点左上角齿轮 → 添加站点，或从剪贴板/文件批量导入配置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.stations) { station in
                    NavigationLink {
                        StationDetailView(station: station, initial: result(for: station), date: dateText)
                    } label: {
                        StationRow(station: station, result: result(for: station))
                    }
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                Task { await refresh() }
            } label: {
                HStack(spacing: 8) {
                    if isRefreshing { ProgressView().tint(.white) }
                    Text(isRefreshing ? "正在读取…" : "刷新全部站点")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRefreshing || store.stations.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: 逻辑

    private func result(for station: Station) -> StationResult? {
        results.first { $0.id == station.id }
    }

    private func refresh() async {
        guard !store.stations.isEmpty else { return }
        isRefreshing = true
        let snapshot = store.stations
        let day = dateText
        let fresh = await RevenueService.refreshAll(snapshot, date: day)
        results = fresh
        isRefreshing = false
    }

    private func exportSummary() {
        do {
            let url = try CSVExporter.writeSummary(results, date: dateText)
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
                } else {
                    Text("\(result?.count ?? 0) 笔 · \(Fmt.volume(result?.volume ?? 0)) 升")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("¥" + Fmt.money(result?.amount ?? 0))
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
