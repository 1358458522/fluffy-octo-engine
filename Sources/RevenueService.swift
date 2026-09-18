import Foundation

enum RevenueService {

    /// 拉取单个站点当日数据
    static func refresh(_ station: Station, date: String) async -> StationResult {
        do {
            let aggregate = try await DatabaseService.fetchDay(station, date: date)
            return StationResult(
                id: station.id,
                stationName: station.name,
                date: date,
                count: aggregate.count,
                amount: aggregate.amount,
                volume: aggregate.volume,
                shifts: aggregate.shifts,
                timing: timing(for: aggregate),
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

    /// 交班状态推算：取"最后交易距今超过 90 分钟"作为已交班兜底判据
    /// （与桌面端模板算法的兜底分支一致；后续可接入 6 日班次模板精算）
    private static func timing(for aggregate: DayAggregate) -> ShiftTiming {
        guard let last = Fmt.parse(aggregate.lastTime) else { return .unknown }
        return Date().timeIntervalSince(last) > 90 * 60 ? .closed : .running
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
