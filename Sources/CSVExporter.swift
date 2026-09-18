import Foundation

enum CSVExporter {

    /// 汇总导出：每站一行 + 各班次明细
    static func writeSummary(_ results: [StationResult], date: String) throws -> URL {
        var lines: [String] = []
        lines.append("站点,营业日期,营业额,销量(升),交易笔数,交班状态,备注")
        for r in results {
            lines.append([
                csv(r.stationName),
                csv(r.date),
                String(format: "%.2f", r.amount),
                String(format: "%.2f", r.volume),
                String(r.count),
                csv(r.timing.rawValue),
                csv(r.error ?? "")
            ].joined(separator: ","))
        }

        lines.append("")
        lines.append("站点,班次,营业额,销量(升),交易笔数,首笔时间,末笔时间")
        for r in results where !r.shifts.isEmpty {
            for s in r.shifts {
                lines.append([
                    csv(r.stationName),
                    String(s.shift),
                    String(format: "%.2f", s.amount),
                    String(format: "%.2f", s.volume),
                    String(s.count),
                    csv(s.firstTime ?? ""),
                    csv(s.lastTime ?? "")
                ].joined(separator: ","))
            }
        }

        return try write(lines.joined(separator: "\r\n"), name: "天天油报_汇总_\(date).csv")
    }

    /// 逐笔明细导出
    static func writeTrades(_ rows: [TradeRow], stationName: String, date: String, shift: Int?) throws -> URL {
        var lines: [String] = []
        lines.append("站点,交易时间,班次,油枪,油品,数量,金额,支付方式,支付状态,加油员")
        for row in rows {
            lines.append([
                csv(stationName),
                csv(row.tradeTime),
                String(row.shift),
                csv(row.fipID),
                csv(row.productName),
                String(format: "%.2f", row.volume),
                String(format: "%.2f", row.amount),
                csv(row.payMode),
                csv(row.paidState),
                csv(row.attendant)
            ].joined(separator: ","))
        }
        let suffix = shift.map { "第\($0)班" } ?? "全天"
        return try write(lines.joined(separator: "\r\n"), name: "天天油报_明细_\(stationName)_\(date)_\(suffix).csv")
    }

    // MARK: - 私有

    private static func csv(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func write(_ content: String, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ttyb-export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        // 加 BOM，保证 Excel 打开中文不乱码
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(content.utf8))
        try data.write(to: url, options: .atomic)
        return url
    }
}
