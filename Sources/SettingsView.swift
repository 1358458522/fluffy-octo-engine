import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.dismiss) private var dismiss

    @State private var editingStation: Station?
    @State private var isAdding = false
    @State private var showImport = false
    @State private var importText = ""
    @State private var showsFileImporter = false
    @State private var importedFileName: String?
    @State private var importAlert: AlertPayload?
    @State private var dismissAfterAlert = false
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
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .navigationBarTrailing) {
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
                EmptyHint(icon: "building.2",
                          title: "还没有站点",
                          message: "点底部「添加站点」，或用下方「批量导入配置」。")
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
        Section {
            InfoRow(title: "站点数量", value: "\(store.stations.count)")
            InfoRow(title: "版本", value: appVersion)
            Text("手机流量直连各站云库取营业额，数据不经过任何第三方服务器。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("关于")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version)（\(build)）"
    }

    private var importSheet: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        showsFileImporter = true
                    } label: {
                        Label("从文件导入", systemImage: "folder")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        importText = UIPasteboard.general.string ?? ""
                        importedFileName = nil
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                if let importedFileName {
                    Text("已载入文件：\(importedFileName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }

                TextEditor(text: $importText)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.35))
                    )
                    .padding(.horizontal)

                Text("同名站点会被覆盖")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            .navigationTitle("批量导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { showImport = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("导入") { runImport() }
                        .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(
                isPresented: $showsFileImporter,
                allowedContentTypes: [.json, .plainText, .text],
                allowsMultipleSelection: false,
                onCompletion: handleFileImport
            )
            .alert(item: $importAlert) { payload in
                Alert(
                    title: Text(payload.title),
                    message: Text(payload.message),
                    dismissButton: .default(Text("好")) {
                        // 导入成功：确认后自动关闭导入面板；失败则留在面板里让用户改内容
                        if dismissAfterAlert {
                            dismissAfterAlert = false
                            showImport = false
                        }
                    }
                )
            }
        }
    }

    // MARK: 逻辑

    private func runImport() {
        dismissAfterAlert = false
        do {
            let count = try store.importJSON(importText)
            importText = ""
            importedFileName = nil
            dismissAfterAlert = true
            importAlert = AlertPayload(title: "导入完成", message: "已导入 \(count) 个站点（同名站点已覆盖）。")
        } catch {
            importAlert = AlertPayload(title: "导入失败", message: error.localizedDescription)
        }
    }

    /// 从「文件」App 选择 JSON 配置文件（iCloud 云盘 / 我的 iPhone / 微信、QQ 的“用其他应用打开”均可）
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let text = decodeConfigText(data) else {
                    importAlert = AlertPayload(title: "读取失败", message: "文件不是可识别的文本编码（支持 UTF-8 / UTF-16 / GB18030）。")
                    return
                }
                importText = text
                importedFileName = url.lastPathComponent
            } catch {
                importAlert = AlertPayload(title: "读取失败", message: error.localizedDescription)
            }
        case .failure(let error):
            importAlert = AlertPayload(title: "选择文件失败", message: error.localizedDescription)
        }
    }

    /// 依次尝试 UTF-8 / UTF-16 / GB18030
    private func decodeConfigText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb)) { return text }
        return nil
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

                Section {
                    TextField("账号", text: $draft.user)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("密码", text: $draft.pwd)
                    Toggle("强制加密连接（TLS）", isOn: $draft.useTLS)
                } header: {
                    Text("云库账号")
                } footer: {
                    Text("云库不要求加密，请保持「关闭」。iOS 真机上加密连接会触发底层崩溃导致闪退（已实测），请勿打开。")
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
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
