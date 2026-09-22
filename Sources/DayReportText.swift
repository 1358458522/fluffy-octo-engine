import Foundation

/// 站点详情纯文本，供「复制全部」使用，口径与页面一致。
/// 段落顺序：全天合计 → 各班次明细（含时段与交班状态）→ 全天按油品（只列升数与笔数）。
enum DayReportText {

    static func make(result: StationResult, station: Station) -> String {
        var lines: [String] = []

        lines.append("\(station.name) (\(station.displayAddress))")
        lines.append("数据源: 云端    营业日期: \(result.date)")

        lines.append("")
        lines.append("全天合计")
        lines.append("  营业额(元)  " + Fmt.money(result.amount))
        lines.append("  油量(升)    " + Fmt.volume(result.volume))
        lines.append("  交易笔数    " + "\(result.count)")

        lines.append("")
        lines.append("各班次明细")
        lines.append("  " + pad("班次", 8) + pad("营业额(元)", 16) + pad("油量(升)", 16) + pad("时段", 46) + "状态")
        for shift in result.shifts {
            lines.append(
                "  " + pad("\(shift.shift)", 8)
                    + pad(Fmt.money(shift.amount), 16)
                    + pad(Fmt.volume(shift.volume), 16)
                    + pad(shift.period, 46)
                    + shift.timing.rawValue
            )
        }

        if !result.products.isEmpty {
            lines.append("")
            lines.append("全天按油品")
            lines.append("  " + pad("油品代码", 14) + pad("油品名称", 16) + pad("油量(升)", 16) + "笔数")
            for item in result.products {
                lines.append(
                    "  " + pad(item.code, 14)
                        + pad(item.name, 16)
                        + pad(Fmt.volume(item.volume), 16)
                        + "\(item.count)"
                )
            }
        }

        return lines.joined(separator: "\n")
    }

    /// 营业日区间汇总纯文本（口径与页面一致：合计 → 按营业日 → 按油品只列升数与笔数）
    static func makeRange(result: DateRangeResult, station: Station) -> String {
        var lines: [String] = []

        lines.append("\(station.name) (\(station.displayAddress))")
        lines.append("数据源: 云端    营业日期区间: \(result.from) ~ \(result.to)")

        lines.append("")
        lines.append("区间合计")
        lines.append("  营业额(元)  " + Fmt.money(result.amount))
        lines.append("  油量(升)    " + Fmt.volume(result.volume))
        lines.append("  交易笔数    \(result.count)")
        lines.append("  营业日数    \(result.days)")
        if let first = result.firstTime, let last = result.lastTime {
            lines.append("  首笔时间    \(first)")
            lines.append("  末笔时间    \(last)")
        }

        if !result.daily.isEmpty {
            lines.append("")
            lines.append("按营业日")
            lines.append("  " + pad("营业日期", 14) + pad("营业额(元)", 16) + pad("油量(升)", 16) + "笔数")
            for item in result.daily {
                lines.append(
                    "  " + pad(item.date, 14)
                        + pad(Fmt.money(item.amount), 16)
                        + pad(Fmt.volume(item.volume), 16)
                        + "\(item.count)"
                )
            }
        }

        if !result.products.isEmpty {
            lines.append("")
            lines.append("区间按油品")
            lines.append("  " + pad("油品代码", 14) + pad("油品名称", 16) + pad("油量(升)", 16) + "笔数")
            for item in result.products {
                lines.append(
                    "  " + pad(item.code, 14)
                        + pad(item.name, 16)
                        + pad(Fmt.volume(item.volume), 16)
                        + "\(item.count)"
                )
            }
        }

        return lines.joined(separator: "\n")
    }

    /// 按显示宽度补齐（中文按 2 列计），对齐电脑端等宽排版
    private static func pad(_ text: String, _ width: Int) -> String {
        var display = 0
        for scalar in text.unicodeScalars {
            display += scalar.value > 0x2E7F ? 2 : 1
        }
        return text + String(repeating: " ", count: max(1, width - display))
    }
}
