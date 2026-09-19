import Foundation
import SwiftUI

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

// MARK: - 交班状态

/// 交班状态。判定算法与电脑端 `judge_shift_status` 完全一致：
/// 1) 有班次时段模板时，把模板基准日的同班次时段整体平移到查询日：
///    now >= 预计交班时刻（末笔交易 +3 分钟缓冲）→ 已交班
///    已过开班时刻但未到交班时刻                 → 未交班(营业中)
///    尚未到开班时刻                             → 未交班(未到交班点)
/// 2) 模板缺失时兜底：末笔交易距今 > 90 分钟视为已交班。
enum ShiftTiming: String, Codable {
    case closed = "已交班"
    case running = "未交班(营业中)"
    case notYet = "未交班(未到交班点)"
    case unknown = "未知"

    var isClosed: Bool { self == .closed }

    /// 电脑端配色：已交班绿字（#0b7a3b）、未交班红字（#b3261e）
    var displayColor: Color {
        switch self {
        case .closed:
            return Color(red: 0.043, green: 0.478, blue: 0.231)
        case .running, .notYet:
            return Color(red: 0.702, green: 0.149, blue: 0.118)
        case .unknown:
            return Color.secondary
        }
    }
}

// MARK: - 取数结果

/// 单个班次的营业额与交班状态
struct ShiftRevenue: Identifiable, Hashable {
    var id: Int { shift }
    var shift: Int
    var count: Int
    var amount: Double
    var volume: Double
    /// 该班次首笔交易时间（yyyy-MM-dd HH:mm:ss）
    var firstTime: String?
    /// 该班次末笔交易时间（yyyy-MM-dd HH:mm:ss）
    var lastTime: String?
    /// 交班状态（电脑端同口径）
    var timing: ShiftTiming = .unknown

    /// 时段文本，与电脑端 "begin ~ end" 一致
    var period: String {
        guard let firstTime, let lastTime, !firstTime.isEmpty, !lastTime.isEmpty else { return "" }
        return "\(firstTime) ~ \(lastTime)"
    }
}

/// 全天按油品
struct ProductStat: Identifiable, Hashable {
    var id: String { code }
    var code: String
    var name: String
    var count: Int
    var volume: Double
    var amount: Double
}

/// 全天按支付方式
struct PayStat: Identifiable, Hashable {
    var id: String { payMode }
    var payMode: String
    var count: Int
    var volume: Double
    var amount: Double
}

/// 班次时段模板（电脑端 `build_shift_template` 的等价结构）
struct ShiftTemplate {
    /// 模板基准日 yyyy-MM-dd
    var refDate: String
    /// 班次号 -> 该班次在基准日的开始 / 结束时刻
    var windows: [Int: Window]

    struct Window {
        var begin: Date
        var end: Date
    }
}

/// 一个站点的当日结果（全天口径）
struct StationResult: Identifiable {
    let id: UUID
    var stationName: String
    var date: String
    var count: Int
    var amount: Double
    var volume: Double
    var shifts: [ShiftRevenue]
    /// 全天按油品
    var products: [ProductStat] = []
    /// 全天按支付方式
    var pays: [PayStat] = []
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

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
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

    /// "2026-09-18" 转为当天 00:00 的 Date
    static func parseDay(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return dayParser.date(from: String(text.prefix(10)))
    }
}
