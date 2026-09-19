import SwiftUI
import UIKit

/// 诊断页：真机闪退排查用。
/// 1) 连通性探针：对选定站点逐项测试三种连接方式（一次只跑一项，串行）；
/// 2) 上一次崩溃报告：崩溃信号 + 调用栈 + 崩溃前运行日志；
/// 3) 本次运行日志：每一步取数的阶段留痕。
struct DiagnosticsView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.dismiss) private var dismiss

    @State private var probeStationID: UUID?
    @State private var probeLines: [String] = []
    @State private var runningMode: DatabaseService.ProbeMode?
    @State private var crashText: String?
    @State private var traceText: String = ""
    @State private var showShare = false
    @State private var shareItems: [Any] = []
    @State private var alert: AlertPayload?
    @State private var confirmClear = false

    private var probeStation: Station? {
        store.stations.first { $0.id == probeStationID } ?? store.stations.first
    }

    var body: some View {
        NavigationStack {
            List {
                probeSection
                crashSection
                traceSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                if probeStationID == nil { probeStationID = store.stations.first?.id }
                reload()
            }
            .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
            .alert(item: $alert) { payload in
                Alert(title: Text(payload.title), message: Text(payload.message), dismissButton: .default(Text("好")))
            }
            .confirmationDialog("确认清空诊断日志？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空运行日志与崩溃记录", role: .destructive) {
                    Diag.clearAll()
                    reload()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - 连通性探针

    private var probeSection: some View {
        Section {
            if store.stations.isEmpty {
                EmptyHint(icon: "building.2",
                          title: "还没有站点",
                          message: "请先到设置里添加或导入配置。")
            } else {
                Picker("测试站点", selection: $probeStationID) {
                    ForEach(store.stations) { station in
                        Text(station.name).tag(Optional(station.id))
                    }
                }

                ForEach(DatabaseService.ProbeMode.allCases, id: \.self) { mode in
                    Button {
                        run(mode)
                    } label: {
                        HStack {
                            Text(mode.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            if runningMode == mode { ProgressView() }
                        }
                    }
                    .disabled(runningMode != nil || probeStation == nil)
                }

                if let station = probeStation {
                    Text("目标：\(station.displayAddress) · 库 \(station.db) · 用户 \(station.user)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                ForEach(Array(probeLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(for: line))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("连通性探针")
        } footer: {
            Text("一次只跑一项、串行执行，不会并发连库。App 默认用「加密 + 信任服务端证书」；若只有「不加密」能通，请到设置里关掉该站的加密开关。")
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("✅") { return .green }
        if line.hasPrefix("❌") { return .red }
        return .primary
    }

    private func run(_ mode: DatabaseService.ProbeMode) {
        guard let station = probeStation else { return }
        runningMode = mode
        Task {
            let line = await DatabaseService.probe(station, mode: mode)
            probeLines.insert("[\(Fmt.time(Date()))] \(line)", at: 0)
            runningMode = nil
            reload()
        }
    }

    // MARK: - 崩溃报告

    private var crashSection: some View {
        Section {
            if let crashText {
                Text(crashText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(80)
                Button {
                    share(crashText, name: "崩溃报告")
                } label: {
                    Label("分享崩溃报告", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = crashText
                    alert = AlertPayload(title: "已复制", message: "崩溃报告已复制到剪贴板，可直接粘贴发给我。")
                } label: {
                    Label("复制崩溃报告", systemImage: "doc.on.doc")
                }
            } else {
                EmptyHint(icon: "checkmark.seal",
                          title: "没有崩溃记录",
                          message: "若刚发生过闪退，重新打开 App 后再进本页即可看到。")
            }
        } header: {
            Text("上一次崩溃报告")
        }
    }

    // MARK: - 运行日志

    private var traceSection: some View {
        Section {
            Text(traceText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(200)

            Button {
                share(traceText, name: "运行日志")
            } label: {
                Label("分享运行日志", systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive) {
                confirmClear = true
            } label: {
                Label("清空日志", systemImage: "trash")
            }
        } header: {
            Text("本次运行日志")
        }
    }

    // MARK: - 逻辑

    private func reload() {
        crashText = Diag.previousCrashText()
        traceText = Diag.traceText(maxLines: 200)
    }

    private func share(_ text: String, name: String) {
        let url = Diag.documentsURL.appendingPathComponent("\(name)-分享.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareItems = [url]
            showShare = true
        } catch {
            UIPasteboard.general.string = text
            alert = AlertPayload(title: "已复制到剪贴板", message: "文件写入失败，内容已复制，可直接粘贴。")
        }
    }
}
