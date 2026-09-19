import Foundation

enum RevenueService {

    /// 拉取单个站点当日数据（全天口径：各班次 + 全天合计 + 按油品 + 按支付方式 + 交班状态）
    static func refresh(_ station: Station, date: String) async -> StationResult {
        do {
            let aggregate = try await DatabaseService.fetchDay(station, date: date)
            let shifts = statusApplied(
                aggregate.shifts,
                template: aggregate.template,
                date: date
            )
            return StationResult(
                id: station.id,
                stationName: station.name,
                date: date,
                count: aggregate.count,
                amount: aggregate.amount,
                volume: aggregate.volume,
                shifts: shifts,
                products: aggregate.products,
                pays: aggregate.pays,
                timing: stationTiming(shifts),
                error: nil,
                updatedAt: Date()
            )
        } catch {
            return StationResult(
                id: station.id,
                stationName: station.name,
                date: date,
                count: 0,
                amount: 0,
                volume: 0,
                shifts: [],
                products: [],
                pays: [],
                timing: .unknown,
                error: friendly(error),
                updatedAt: Date()
            )
        }
    }

    /// 并发拉取全部站点（默认最多 6 路并发，避免站点侧压力）
    static func refreshAll(
        _ stations: [Station],
        date: String,
        maxConcurrent: Int = 6
    ) async -> [StationResult] {
        guard !stations.isEmpty else { return [] }

        let order = Dictionary(uniqueKeysWithValues: stations.enumerated().map { ($1.id, $0) })
        var collected: [StationResult] = []
        collected.reserveCapacity(stations.count)

        await withTaskGroup(of: StationResult.self) { group in
            var next = 0
            let total = stations.count

            while next < min(maxConcurrent, total) {
                let station = stations[next]
                group.addTask { await refresh(station, date: date) }
                next += 1
            }

            for await result in group {
                collected.append(result)
                if next < total {
                    let station = stations[next]
                    group.addTask { await refresh(station, date: date) }
                    next += 1
                }
            }
        }

        return collected.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }

    // MARK: - 交班状态（与电脑端 judge_shift_status 同算法）

    /// 给每个班次打上交班状态
    static func statusApplied(
        _ shifts: [ShiftRevenue],
        template: ShiftTemplate?,
        date: String,
        now: Date = Date()
    ) -> [ShiftRevenue] {
        shifts.map { shift in
            var item = shift
            item.timing = judge(shift, template: template, date: date, now: now)
            return item
        }
    }

    /// 单班次交班判定：
    /// - 有模板：模板基准日同班次时段整体平移到查询日，与当前时间比较
    /// - 无模板：末笔交易距今 > 90 分钟视为已交班（兜底，与电脑端一致）
    static func judge(
        _ shift: ShiftRevenue,
        template: ShiftTemplate?,
        date: String,
        now: Date = Date()
    ) -> ShiftTiming {
        if let template,
           let window = template.windows[shift.shift],
           let refDay = Fmt.parseDay(template.refDate) {
            let calendar = Calendar.current
            let target = Fmt.parseDay(date) ?? now
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: refDay),
                to: calendar.startOfDay(for: target)
            ).day ?? 0

            guard let begin = calendar.date(byAdding: .day, value: days, to: window.begin),
                  let end = calendar.date(byAdding: .day, value: days, to: window.end) else {
                return fallbackTiming(shift.lastTime, now: now)
            }

            // 模板 end 为该班次末笔交易时间，交班动作通常在其后 1~2 分钟完成；
            // 加 3 分钟缓冲，避免末笔交易与交班完成之间的窗口被误判为已交班（与电脑端一致）
            if now >= end.addingTimeInterval(3 * 60) { return .closed }
            if now >= begin { return .running }
            return .notYet
        }
        return fallbackTiming(shift.lastTime, now: now)
    }

    /// 模板缺失时的兜底判定
    private static func fallbackTiming(_ lastTime: String?, now: Date) -> ShiftTiming {
        guard let last = Fmt.parse(lastTime) else { return .unknown }
        return now.timeIntervalSince(last) > 90 * 60 ? .closed : .running
    }

    /// 站点级状态：全部班次已交班 → 已交班；存在营业中 → 未交班(营业中)；
    /// 仅有未到交班点 → 未交班(未到交班点)；无班次 → 未知
    static func stationTiming(_ shifts: [ShiftRevenue]) -> ShiftTiming {
        guard !shifts.isEmpty else { return .unknown }
        if shifts.allSatisfy({ $0.timing == .closed }) { return .closed }
        if shifts.contains(where: { $0.timing == .running }) { return .running }
        if shifts.contains(where: { $0.timing == .notYet }) { return .notYet }
        return .unknown
    }

    private static func friendly(_ error: Error) -> String {
        let text = "\(error)"
        let lower = text.lowercased()
        if lower.contains("refused") || lower.contains("timed out") || lower.contains("timeout") || lower.contains("unreachable") {
            return "连不上云库（检查地址/端口与手机网络）"
        }
        if lower.contains("login") || lower.contains("password") || lower.contains("18456") {
            return "云库账号或密码不正确"
        }
        if text.count > 120 {
            return String(text.prefix(120)) + "…"
        }
        return text
    }
}
