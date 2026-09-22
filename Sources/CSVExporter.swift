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
        lines.append("站点,班次,营业额,销量(升),交易笔数,首笔时间,末笔时间,交班状态")
        for r in results where !r.shifts.isEmpty {
            for s in r.shifts {
                lines.append([
                    csv(r.stationName),
                    String(s.shift),
                    String(format: "%.2f", s.amount),
                    String(format: "%.2f", s.volume),
                    String(s.count),
                    csv(s.firstTime ?? ""),
                    csv(s.lastTime ?? ""),
                    csv(s.timing.rawValue)
                ].joined(separator: ","))
            }
        }

        lines.append("")
        lines.append("站点,油品代码,油品名称,销量(升),营业额,交易笔数")
        for r in results where !r.products.isEmpty {
            for p in r.products {
                lines.append([
                    csv(r.stationName),
                    csv(p.code),
                    csv(p.name),
                    String(format: "%.2f", p.volume),
                    String(format: "%.2f", p.amount),
                    String(p.count)
                ].joined(separator: ","))
            }
        }

        lines.append("")
        lines.append("站点,支付方式,销量(升),营业额,交易笔数")
        for r in results where !r.pays.isEmpty {
            for p in r.pays {
                lines.append([
                    csv(r.stationName),
                    csv(p.payMode),
                    String(format: "%.2f", p.volume),
                    String(format: "%.2f", p.amount),
                    String(p.count)
                ].joined(separator: ","))
            }
        }

        return try write(lines.joined(separator: "\r\n"), name: "天天油报_汇总_\(date).csv")
    }

    /// 逐笔明细导出（单日 / 区间共用；`label` 非空时覆盖文件名后缀）
    static func writeTrades(
        _ rows: [TradeRow],
        stationName: String,
        date: String,
        shift: Int?,
        label: String? = nil
    ) throws -> URL {
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
        let suffix = label ?? (shift.map { "第\($0)班" } ?? "全天")
        return try write(lines.joined(separator: "\r\n"), name: "天天油报_明细_\(stationName)_\(date)_\(suffix).csv")
    }

    /// 区间汇总导出：合计 + 按营业日 + 按油品（口径同页面，不导出按支付方式）
    static func writeRange(_ result: DateRangeResult, stationName: String) throws -> URL {
        var lines: [String] = []

        lines.append("站点,开始日期,结束日期,营业日数,营业额,销量(升),交易笔数,首笔时间,末笔时间")
        lines.append([
            csv(stationName),
            csv(result.from),
            csv(result.to),
            "\(result.days)",
            String(format: "%.2f", result.amount),
            String(format: "%.2f", result.volume),
            "\(result.count)",
            csv(result.firstTime ?? ""),
            csv(result.lastTime ?? "")
        ].joined(separator: ","))

        lines.append("")
        lines.append("站点,营业日期,营业额,销量(升),交易笔数")
        for day in result.daily {
            lines.append([
                csv(stationName),
                csv(day.date),
                String(format: "%.2f", day.amount),
                String(format: "%.2f", day.volume),
                "\(day.count)"
            ].joined(separator: ","))
        }

        lines.append("")
        lines.append("站点,油品代码,油品名称,销量(升),营业额,交易笔数")
        for item in result.products {
            lines.append([
                csv(stationName),
                csv(item.code),
                csv(item.name),
                String(format: "%.2f", item.volume),
                String(format: "%.2f", item.amount),
                "\(item.count)"
            ].joined(separator: ","))
        }

        let name = "天天油报_区间汇总_\(stationName)_\(result.from)_\(result.to).csv"
        return try write(lines.joined(separator: "\r\n"), name: name)
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
