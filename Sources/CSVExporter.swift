import Foundation
import UIKit

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

/// 「按油品升数」白底小卡片 PNG（只含各油品升数，不含站名与日期），供系统分享面板发送
enum OilCardImage {

    static func render(_ products: [ProductStat]) throws -> URL {
        guard !products.isEmpty else {
            throw NSError(domain: "OilCardImage", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可分享的油品数据"])
        }

        let rows = products.map { (name: $0.name.isEmpty ? $0.code : $0.name,
                                   value: "\(Fmt.volume($0.volume)) 升") }

        // 布局（pt）：560 宽白底卡片，上下留白 + 每行一行油品
        let sidePadding: CGFloat = 40
        let topBottom: CGFloat = 44
        let rowHeight: CGFloat = 64
        let width: CGFloat = 560
        let height = topBottom * 2 + CGFloat(rows.count) * rowHeight

        let nameFont = UIFont.systemFont(ofSize: 30, weight: .regular)
        let valueFont = UIFont.monospacedDigitSystemFont(ofSize: 30, weight: .semibold)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

            for (index, row) in rows.enumerated() {
                let y = topBottom + CGFloat(index) * rowHeight
                // 垂直居中
                let nameAttrs: [NSAttributedString.Key: Any] = [
                    .font: nameFont,
                    .foregroundColor: UIColor.black
                ]
                let nameBaseline = y + (rowHeight - nameFont.lineHeight) / 2
                (row.name as NSString).draw(
                    at: CGPoint(x: sidePadding, y: nameBaseline),
                    withAttributes: nameAttrs
                )

                let valueAttrs: [NSAttributedString.Key: Any] = [
                    .font: valueFont,
                    .foregroundColor: UIColor.black
                ]
                let valueSize = (row.value as NSString).size(withAttributes: valueAttrs)
                (row.value as NSString).draw(
                    at: CGPoint(x: width - sidePadding - valueSize.width, y: y + (rowHeight - valueSize.height) / 2),
                    withAttributes: valueAttrs
                )
            }
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ttyb-export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let url = dir.appendingPathComponent("油品升数_\(formatter.string(from: Date())).png")
        guard let data = image.pngData() else {
            throw NSError(domain: "OilCardImage", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "PNG 编码失败"])
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
