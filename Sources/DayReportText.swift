import Foundation

/// 站点详情纯文本（结构与电脑端「XX 详情」窗口一致），供「复制全部」使用。
/// 段落顺序：全天合计 → 各班次明细（含时段与交班状态）→ 全天按油品 → 全天按支付方式。
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
            lines.append("  " + pad("油品代码", 14) + pad("油品名称", 16) + pad("油量(升)", 16) + "营业额(元)")
            for item in result.products {
                lines.append(
                    "  " + pad(item.code, 14)
                        + pad(item.name, 16)
                        + pad(Fmt.volume(item.volume), 16)
                        + Fmt.money(item.amount)
                )
            }
        }

        if !result.pays.isEmpty {
            lines.append("")
            lines.append("全天按支付方式")
            lines.append("  " + pad("支付方式", 14) + pad("油量(升)", 16) + "营业额(元)")
            for item in result.pays {
                lines.append(
                    "  " + pad(item.payMode, 14)
                        + pad(Fmt.volume(item.volume), 16)
                        + Fmt.money(item.amount)
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
