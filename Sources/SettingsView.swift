import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.dismiss) private var dismiss

    @State private var editingStation: Station?
    @State private var isAdding = false
    @State private var showImport = false
    @State private var importText = ""
    @State private var showShare = false
    @State private var exportItems: [Any] = []
    @State private var alert: AlertPayload?

    var body: some View {
        NavigationStack {
            List {
                sitesSection
                bulkSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    isAdding = true
                } label: {
                    Label("添加站点", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
            .sheet(item: $editingStation) { station in
                StationEditView(station: station, isNew: false)
            }
            .sheet(isPresented: $isAdding) {
                StationEditView(station: Station(), isNew: true)
            }
            .sheet(isPresented: $showImport) { importSheet }
            .sheet(isPresented: $showShare) { ShareSheet(items: exportItems) }
            .alert(item: $alert) { payload in
                Alert(title: Text(payload.title), message: Text(payload.message), dismissButton: .default(Text("好")))
            }
        }
    }

    // MARK: 子视图

    private var sitesSection: some View {
        Section {
            if store.stations.isEmpty {
                Text("还没有站点，点底部「添加站点」，或用下方「批量导入配置」。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.stations) { station in
                    Button {
                        editingStation = station
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(station.name.isEmpty ? "未命名站点" : station.name)
                                    .foregroundStyle(.primary)
                                Text("\(station.displayAddress) · \(station.db) · \(station.user)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete { store.remove(at: $0) }
                .onMove { store.move(from: $0, to: $1) }
            }
        } header: {
            Text("站点（\(store.stations.count)）")
        } footer: {
            Text("左滑删除，右侧「编辑」可拖动排序。凭据以 AES-GCM 加密存放本机，密钥由 iOS 钥匙串保管。")
        }
    }

    private var bulkSection: some View {
        Section("配置批量处理") {
            Button {
                showImport = true
            } label: {
                Label("批量导入配置", systemImage: "square.and.arrow.down")
            }
            Button {
                exportConfig()
            } label: {
                Label("导出配置 JSON", systemImage: "square.and.arrow.up")
            }
            .disabled(store.stations.isEmpty)
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                    .foregroundStyle(.secondary)
            }
            Text("手机流量直连各站云库取营业额，数据不经过任何第三方服务器。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var importSheet: some View {
        NavigationStack {
            VStack(spacing: 10) {
                TextEditor(text: $importText)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.35))
                    )
                    .padding(.horizontal)
                    .padding(.top, 8)

                HStack {
                    Button {
                        importText = UIPasteboard.general.string ?? ""
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)

                    Text("同名站点会被覆盖")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("批量导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { showImport = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("导入") { runImport() }
                        .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: 逻辑

    private func runImport() {
        do {
            let count = try store.importJSON(importText)
            importText = ""
            showImport = false
            alert = AlertPayload(title: "导入完成", message: "已导入 \(count) 个站点。")
        } catch {
            alert = AlertPayload(title: "导入失败", message: error.localizedDescription)
        }
    }

    private func exportConfig() {
        let text = store.exportJSON()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ttyb-export", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("天天油报_站点配置.json")
            try Data(text.utf8).write(to: url, options: .atomic)
            exportItems = [url]
            showShare = true
        } catch {
            alert = AlertPayload(title: "导出失败", message: error.localizedDescription)
        }
    }
}

// MARK: - 站点编辑

struct StationEditView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Station
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testOK = false

    private let isNew: Bool

    init(station: Station, isNew: Bool) {
        _draft = State(initialValue: station)
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("站点信息") {
                    TextField("站名", text: $draft.name)
                    TextField("云库地址（IP,端口）", text: $draft.server)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("数据库名", text: $draft.db)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("云库账号") {
                    TextField("账号", text: $draft.user)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("密码", text: $draft.pwd)
                    Toggle("强制加密连接（TLS）", isOn: $draft.useTLS)
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("测试连接")
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                    }
                    .disabled(isTesting || draft.hostPort.host.isEmpty)

                    if let testMessage {
                        Text(testMessage)
                            .font(.footnote)
                            .foregroundStyle(testOK ? .green : .red)
                    }
                } footer: {
                    Text("保存后凭据立即加密落盘。建议使用只读账号。")
                }
            }
            .navigationTitle(isNew ? "添加站点" : "编辑站点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        store.upsert(draft)
                        dismiss()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.hostPort.host.isEmpty)
                }
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        testMessage = nil
        do {
            let aggregate = try await DatabaseService.fetchDay(draft, date: Fmt.today())
            testOK = true
            testMessage = "连接成功：今日 \(aggregate.count) 笔，¥\(Fmt.money(aggregate.amount))"
        } catch {
            testOK = false
            testMessage = "连接失败：\(error)"
        }
        isTesting = false
    }
}
