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

// MARK: - 首页（站点目录）

/// 首页只做一件事：列出站点，点进去看数据。
/// - 只显示站名，不显示任何金额；
/// - 不做批量查询：首页不发任何云库请求，取数全部在站点详情页里手动、单站、串行完成，
///   避免多站并发连库在自签真机上触发闪退。
struct HomeView: View {
    @EnvironmentObject private var store: ConfigStore

    @State private var showSettings = false
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            List {
                if Diag.hasPreviousCrash() { crashSection }
                stationsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("天天油报")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showDiagnostics = true } label: {
                        Image(systemName: "stethoscope")
                    }
                    .accessibilityLabel("诊断")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
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

    /// 站点列表：一行一个站名
    private var stationsSection: some View {
        Section {
            if store.stations.isEmpty {
                EmptyHint(icon: "building.2",
                          title: "还没有站点",
                          message: "点左上角齿轮 → 添加站点，或从文件 / 剪贴板批量导入配置。")
            } else {
                ForEach(store.stations) { station in
                    NavigationLink {
                        StationDetailView(station: station)
                    } label: {
                        StationRow(station: station)
                    }
                }
            }
        } header: {
            Text(store.stations.isEmpty ? "站点" : "站点 · \(store.stations.count) 座")
        } footer: {
            Text("点站名进入详情页，选好营业日期后手动查询该站数据。")
        }
    }
}

// MARK: - 站点行（只有站名）

struct StationRow: View {
    let station: Station

    var body: some View {
        Text(station.name.isEmpty ? "未命名站点" : station.name)
            .font(.body)
            .lineLimit(1)
            .padding(.vertical, 4)
    }
}
