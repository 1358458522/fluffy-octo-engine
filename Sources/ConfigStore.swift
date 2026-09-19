import Foundation
import SwiftUI
import CryptoKit
import Security

// MARK: - Keychain 密钥

enum KeychainStore {
    private static let service = "com.ttyb.mobile.config"
    private static let account = "stations-master-key"

    /// 取出或生成 32 字节主密钥（用于加密站点配置）
    static func loadOrCreateKey() -> SymmetricKey {
        if let data = read(), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        write(data)
        return key
    }

    private static func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func write(_ data: Data) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - 配置存储

@MainActor
final class ConfigStore: ObservableObject {
    @Published var stations: [Station] = []
    @Published var lastError: String?

    private let fileURL: URL
    private let key: SymmetricKey

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("stations.enc")
        key = KeychainStore.loadOrCreateKey()
        load()
    }

    // MARK: 落盘 / 读取

    func load() {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let plain = try AES.GCM.open(box, using: key)
            stations = try JSONDecoder().decode([Station].self, from: plain)
        } catch {
            lastError = "本地配置解密失败：\(error.localizedDescription)"
        }
    }

    func save() {
        do {
            let plain = try JSONEncoder().encode(stations)
            let sealed = try AES.GCM.seal(plain, using: key)
            guard let combined = sealed.combined else { return }
            try combined.write(to: fileURL, options: .atomic)
        } catch {
            lastError = "配置保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: 增删改

    func upsert(_ station: Station) {
        if let idx = stations.firstIndex(where: { $0.id == station.id }) {
            stations[idx] = station
        } else {
            stations.append(station)
        }
        save()
    }

    func remove(_ station: Station) {
        stations.removeAll { $0.id == station.id }
        save()
    }

    func remove(at offsets: IndexSet) {
        stations.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        stations.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: 批量导入 / 导出（方便从电脑端一次性搬配置）

    /// 支持两种格式：
    /// 1) [{"name":"站名","server":"IP,端口","db":"moms","user":"sa","pwd":"***"}]
    /// 2) {"stations":[ ... ]}
    @discardableResult
    func importJSON(_ text: String, overwriteByName: Bool = true) throws -> Int {
        guard let data = text.data(using: .utf8) else { throw ImportError.badText }
        let decoder = JSONDecoder()

        var incoming: [Station] = []
        if let list = try? decoder.decode([Station].self, from: data) {
            incoming = list
        } else {
            do {
                incoming = try decoder.decode(StationWrapper.self, from: data).stations
            } catch {
                throw ImportError.badFormat(error.localizedDescription)
            }
        }

        // 丢弃缺站名 / 缺云库地址的空条目，避免脏数据落库
        incoming = incoming.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !incoming.isEmpty else {
            throw ImportError.badFormat("文件中没有含 name / server 的站点条目")
        }

        var imported = 0
        for var item in incoming {
            item.id = UUID()
            if item.db.isEmpty { item.db = "moms" }
            if item.user.isEmpty { item.user = "sa" }
            if overwriteByName, let idx = stations.firstIndex(where: { $0.name == item.name }) {
                item.id = stations[idx].id
                stations[idx] = item
            } else {
                stations.append(item)
            }
            imported += 1
        }
        save()
        return imported
    }

    func exportJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(StationWrapper(stations: stations)) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    struct StationWrapper: Codable {
        var stations: [Station]
    }

    enum ImportError: LocalizedError {
        case badText
        case badFormat(String)

        var errorDescription: String? {
            switch self {
            case .badText:
                return "内容不是有效的文本"
            case .badFormat(let detail):
                let head = "不是可识别的配置格式（需为 JSON 数组或含 stations 字段的对象）"
                return detail.isEmpty ? head : "\(head)\n原因：\(detail)"
            }
        }
    }
}
