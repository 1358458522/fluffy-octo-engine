import Foundation

// MARK: - 站点配置

/// 单个站点的云库配置。凭据在本地以 AES-GCM 加密后落盘。
struct Station: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    /// 云库地址，格式 "IP,端口" 或 "IP:端口"；缺端口时回落到 1433
    var server: String = ""
    var db: String = "moms"
    var user: String = "sa"
    var pwd: String = ""
    /// 云库若要求强制加密连接，打开此项
    var useTLS: Bool = false

    /// 解析出的 (host, port)
    var hostPort: (host: String, port: Int) {
        let raw = server
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "，", with: ",")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = raw.lastIndex(where: { $0 == "," || $0 == ":" }) {
            let host = String(raw[raw.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
            let portText = String(raw[raw.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            if let port = Int(portText), port > 0, port <= 65535, !host.isEmpty {
                return (host, port)
            }
        }
        return (raw, 1433)
    }

    var displayAddress: String {
        "\(hostPort.host):\(hostPort.port)"
    }
}

// MARK: - 取数结果

/// 单个班次的营业额
struct ShiftRevenue: Identifiable, Hashable {
    var id: Int { shift }
    var shift: Int
    var count: Int
    var amount: Double
    var volume: Double
    var firstTime: String?
    var lastTime: String?
}

/// 交班状态（本地推算）
enum ShiftTiming: String {
    case closed = "已交班"
    case running = "营业中"
    case unknown = "未知"
}

/// 一个站点的当日结果
struct StationResult: Identifiable {
    let id: UUID
    var stationName: String
    var date: String
    var count: Int
    var amount: Double
    var volume: Double
    var shifts: [ShiftRevenue]
    var timing: ShiftTiming
    var error: String?
    var updatedAt: Date
}

/// 逐笔加油明细
struct TradeRow: Identifiable, Hashable {
    var id = UUID()
    var tradeTime: String
    var shift: Int
    var fipID: String
    var productName: String
    var volume: Double
    var amount: Double
    var payMode: String
    var attendant: String
    var paidState: String
}

// MARK: - 格式化

enum Fmt {
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func today() -> String {
        dateFormatter.string(from: Date())
    }

    static func money(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    static func volume(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func time(_ value: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: value)
    }

    /// "2026-09-18 12:03:11" 转为 Date
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: text)
    }
}
