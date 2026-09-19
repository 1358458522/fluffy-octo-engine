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
/// - 不显示任何金额，也不显示云库/数据库/账号；
/// - 不发任何云库请求、不做批量查询（取数全部在详情页手动、单站、串行）；
/// - 顶部一张渐变概览卡展示在册站点数。
struct HomeView: View {
    @EnvironmentObject private var store: ConfigStore

    @State private var showSettings = false
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            List {
                overviewSection
                stationsSection
            }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
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

    /// 顶部概览卡：在册站点数
    private var overviewSection: some View {
        Section {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("在册站点")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))

                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(store.stations.count)")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text("座")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "fuelpump.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.white.opacity(0.26))
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.06, green: 0.35, blue: 0.68),
                             Color(red: 0.14, green: 0.57, blue: 0.92)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color(red: 0.06, green: 0.35, blue: 0.68).opacity(0.22), radius: 10, x: 0, y: 5)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
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
                ForEach(Array(store.stations.enumerated()), id: \.element.id) { item in
                    NavigationLink {
                        StationDetailView(station: item.element)
                    } label: {
                        StationRow(station: item.element, index: item.offset)
                    }
                }
            }
        } header: {
            Text("全部站点")
        } footer: {
            Text("点站名进入详情，选好营业日期后手动查询该站数据。")
        }
    }
}

// MARK: - 站点行（只有站名）

struct StationRow: View {
    let station: Station
    var index: Int = 0

    private static let palettes: [[Color]] = [
        [Color(red: 0.13, green: 0.48, blue: 0.90), Color(red: 0.26, green: 0.68, blue: 0.98)],
        [Color(red: 0.09, green: 0.60, blue: 0.55), Color(red: 0.26, green: 0.78, blue: 0.68)],
        [Color(red: 0.35, green: 0.36, blue: 0.86), Color(red: 0.56, green: 0.51, blue: 0.95)],
        [Color(red: 0.82, green: 0.55, blue: 0.12), Color(red: 0.94, green: 0.72, blue: 0.26)]
    ]

    private var iconColors: [Color] {
        let list = Self.palettes
        return list[((index % list.count) + list.count) % list.count]
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: iconColors,
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)

                Image(systemName: "fuelpump.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text(station.name.isEmpty ? "未命名站点" : station.name)
                .font(.body.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}
