import Foundation
import SQLServerKit

/// 关键改点提示：
/// 若 CI 编译报错并指向下面 Configuration 初始化里的 `tlsConfiguration:`，
/// 说明该参数不是可选类型，把 `station.useTLS ? .makeClientConfiguration() : nil`
/// 改为恒定的 `.makeClientConfiguration()` 即可，其余代码不受影响。
enum DBError: LocalizedError {
    case emptyServer

    var errorDescription: String? {
        switch self {
        case .emptyServer: return "该站点未配置云库地址"
        }
    }
}

/// 一个站点某营业日的全天口径取数结果。
/// 取数口径与电脑端 fetch_day 一致：营业日全部有数据的班次 + 全天合计 +
/// 全天按油品 + 全天按支付方式，并附带用于交班判定的班次时段模板。
struct DayAggregate {
    var count: Int = 0
    var amount: Double = 0
    var volume: Double = 0
    var firstTime: String?
    var lastTime: String?
    var shifts: [ShiftRevenue] = []
    /// 全天按油品（跨全部班次）
    var products: [ProductStat] = []
    /// 全天按支付方式（跨全部班次）
    var pays: [PayStat] = []
    /// 班次时段模板（交班判定用）
    var template: ShiftTemplate?
}

enum DatabaseService {

    // MARK: - 建连

    private static func withClient<T>(
        _ station: Station,
        _ body: (SQLServerClient) async throws -> T
    ) async throws -> T {
        let host = station.hostPort.host
        guard !host.isEmpty else { throw DBError.emptyServer }

        let configuration = SQLServerClient.Configuration(
            hostname: host,
            port: station.hostPort.port,
            login: .init(
                database: station.db.isEmpty ? "moms" : station.db,
                authentication: .sqlPassword(username: station.user, password: station.pwd)
            ),
            tlsConfiguration: station.useTLS ? .makeClientConfiguration() : nil
        )

        let client = try await SQLServerClient.connect(configuration: configuration)
        do {
            let value = try await body(client)
            try? await client.shutdownGracefully()
            return value
        } catch {
            try? await client.shutdownGracefully()
            throw error
        }
    }

    // MARK: - 当日各班次 + 全天汇总 + 班次时段模板

    static func fetchDay(_ station: Station, date: String) async throws -> DayAggregate {
        try await withClient(station) { client in
            var aggregate = DayAggregate()

            let sql = """
            SELECT FBusinessShiftNo AS shiftNo,
                   COUNT(*) AS cnt,
                   CAST(ISNULL(SUM(FTradeAmount), 0) AS float) AS amt,
                   CAST(ISNULL(SUM(FTradeVolume), 0) AS float) AS vol,
                   CONVERT(varchar(19), MIN(FTradeTime), 120) AS tmin,
                   CONVERT(varchar(19), MAX(FTradeTime), 120) AS tmax
            FROM TFuelTradeRecord WITH (NOLOCK)
            WHERE FBusinessDate = '\(date)'
            GROUP BY FBusinessShiftNo
            ORDER BY FBusinessShiftNo
            """

            let rows = try await client.query(sql)

            for row in rows {
                let shift = row.column("shiftNo")?.int ?? 0
                let count = row.column("cnt")?.int ?? 0
                let amount = row.column("amt")?.double ?? 0
                let volume = row.column("vol")?.double ?? 0
                let first = row.column("tmin")?.string
                let last = row.column("tmax")?.string

                aggregate.shifts.append(
                    ShiftRevenue(
                        shift: shift,
                        count: count,
                        amount: amount,
                        volume: volume,
                        firstTime: first,
                        lastTime: last
                    )
                )
                aggregate.count += count
                aggregate.amount += amount
                aggregate.volume += volume
                if aggregate.firstTime == nil { aggregate.firstTime = first }
                if let last { aggregate.lastTime = last }
            }

            // 全天按油品 / 按支付方式（与电脑端 fetch_day 同源，表结构差异时自动降级）
            aggregate.products = await productStats(client, date: date)
            aggregate.pays = await payStats(client, date: date)
            // 班次时段模板（交班判定使用）
            aggregate.template = await shiftTemplate(client, date: date)
            return aggregate
        }
    }

    // MARK: - 全天按油品

    private static func productStats(_ client: SQLServerClient, date: String) async -> [ProductStat] {
        let joinedSQL = """
        SELECT CAST(t.FProductSN AS nvarchar(50)) AS pSn,
               CAST(p.FProductName AS nvarchar(100)) AS pName,
               COUNT(*) AS cnt,
               CAST(ISNULL(SUM(t.FTradeVolume), 0) AS float) AS vol,
               CAST(ISNULL(SUM(t.FTradeAmount), 0) AS float) AS amt
        FROM TFuelTradeRecord t WITH (NOLOCK)
        LEFT JOIN TProduct p WITH (NOLOCK) ON p.FProductSN = t.FProductSN
        WHERE t.FBusinessDate = '\(date)'
        GROUP BY t.FProductSN, p.FProductName
        ORDER BY SUM(t.FTradeAmount) DESC
        """

        let plainSQL = """
        SELECT CAST(FProductSN AS nvarchar(50)) AS pSn,
               CAST('' AS nvarchar(100)) AS pName,
               COUNT(*) AS cnt,
               CAST(ISNULL(SUM(FTradeVolume), 0) AS float) AS vol,
               CAST(ISNULL(SUM(FTradeAmount), 0) AS float) AS amt
        FROM TFuelTradeRecord WITH (NOLOCK)
        WHERE FBusinessDate = '\(date)'
        GROUP BY FProductSN
        ORDER BY SUM(FTradeAmount) DESC
        """

        if let rows = try? await client.query(joinedSQL) {
            return rows.map { row in
                ProductStat(
                    code: row.column("pSn")?.string ?? "",
                    name: row.column("pName")?.string ?? "",
                    count: row.column("cnt")?.int ?? 0,
                    volume: row.column("vol")?.double ?? 0,
                    amount: row.column("amt")?.double ?? 0
                )
            }
        }
        if let rows = try? await client.query(plainSQL) {
            return rows.map { row in
                ProductStat(
                    code: row.column("pSn")?.string ?? "",
                    name: row.column("pName")?.string ?? "",
                    count: row.column("cnt")?.int ?? 0,
                    volume: row.column("vol")?.double ?? 0,
                    amount: row.column("amt")?.double ?? 0
                )
            }
        }
        return []
    }

    // MARK: - 全天按支付方式

    private static func payStats(_ client: SQLServerClient, date: String) async -> [PayStat] {
        let sql = """
        SELECT CAST(FPayMode AS nvarchar(50)) AS payMode,
               COUNT(*) AS cnt,
               CAST(ISNULL(SUM(FTradeVolume), 0) AS float) AS vol,
               CAST(ISNULL(SUM(FTradeAmount), 0) AS float) AS amt
        FROM TFuelTradeRecord WITH (NOLOCK)
        WHERE FBusinessDate = '\(date)'
        GROUP BY FPayMode
        ORDER BY SUM(FTradeAmount) DESC
        """

        guard let rows = try? await client.query(sql) else { return [] }
        return rows.map { row in
            PayStat(
                payMode: row.column("payMode")?.string ?? "",
                count: row.column("cnt")?.int ?? 0,
                volume: row.column("vol")?.double ?? 0,
                amount: row.column("amt")?.double ?? 0
            )
        }
    }

    // MARK: - 班次时段模板（交班判定用，等价电脑端 build_shift_template）

    /// 取查询日前最近一个「结构完整日」（含最多班次数）作为模板基准，
    /// 记录该日各班次的典型开始 / 结束时间。无历史完整日时返回 nil。
    private static func shiftTemplate(_ client: SQLServerClient, date: String) async -> ShiftTemplate? {
        let sql = """
        SELECT CONVERT(varchar(10), FBusinessDate, 120) AS d,
               FBusinessShiftNo AS sh,
               CONVERT(varchar(19), MIN(FTradeTime), 120) AS tb,
               CONVERT(varchar(19), MAX(FTradeTime), 120) AS te
        FROM TFuelTradeRecord WITH (NOLOCK)
        WHERE FBusinessDate >= DATEADD(day, -6, CAST('\(date)' AS date))
          AND FBusinessDate < CAST('\(date)' AS date)
        GROUP BY CONVERT(varchar(10), FBusinessDate, 120), FBusinessShiftNo
        ORDER BY d, FBusinessShiftNo
        """

        guard let rows = try? await client.query(sql) else { return nil }

        var byDay: [String: [Int: ShiftTemplate.Window]] = [:]
        for row in rows {
            guard let day = row.column("d")?.string,
                  let shift = row.column("sh")?.int,
                  let begin = Fmt.parse(row.column("tb")?.string),
                  let end = Fmt.parse(row.column("te")?.string) else { continue }
            byDay[day, default: [:]][shift] = ShiftTemplate.Window(begin: begin, end: end)
        }

        // 取最近且班次数最多的完整日（并列时取较晚的一天，与电脑端一致）
        var bestDay: String?
        var bestCount = 0
        for day in byDay.keys.sorted() {
            let count = byDay[day]?.count ?? 0
            if count >= max(bestCount, 1) {
                bestDay = day
                bestCount = count
            }
        }

        guard let refDate = bestDay, let windows = byDay[refDate], !windows.isEmpty else { return nil }
        return ShiftTemplate(refDate: refDate, windows: windows)
    }

    // MARK: - 逐笔明细

    static func fetchTrades(
        _ station: Station,
        date: String,
        shift: Int? = nil,
        limit: Int = 500
    ) async throws -> [TradeRow] {
        try await withClient(station) { client in
            var condition = "t.FBusinessDate = '\(date)'"
            if let shift {
                condition += " AND t.FBusinessShiftNo = \(shift)"
            }

            let sql = """
            SELECT TOP \(limit)
                   CONVERT(varchar(19), t.FTradeTime, 120) AS tradeTime,
                   CAST(ISNULL(t.FBusinessShiftNo, 0) AS int) AS shiftNo,
                   CAST(ISNULL(t.FFipID, '') AS nvarchar(50)) AS fipID,
                   CAST(ISNULL(p.FProductName, '') AS nvarchar(100)) AS productName,
                   CAST(ISNULL(t.FTradeVolume, 0) AS float) AS vol,
                   CAST(ISNULL(t.FTradeAmount, 0) AS float) AS amt,
                   CAST(ISNULL(t.FPayMode, '') AS nvarchar(50)) AS payMode,
                   CAST(ISNULL(t.FAttendant, '') AS nvarchar(50)) AS attendant,
                   CAST(ISNULL(t.FPaid, 0) AS int) AS paid,
                   CAST(ISNULL(t.FMakeout, 0) AS int) AS makeout
            FROM TFuelTradeRecord t WITH (NOLOCK)
            LEFT JOIN TProduct p WITH (NOLOCK) ON p.FProductSN = t.FProductSN
            WHERE \(condition)
            ORDER BY t.FTradeTime DESC
            """

            let rows = try await client.query(sql)
            return rows.map { row in
                let paid = row.column("paid")?.int ?? 0
                let makeout = row.column("makeout")?.int ?? 0
                let state = makeout != 0 ? "挂账" : (paid != 0 ? "已支付" : "未支付")
                return TradeRow(
                    tradeTime: row.column("tradeTime")?.string ?? "",
                    shift: row.column("shiftNo")?.int ?? 0,
                    fipID: row.column("fipID")?.string ?? "",
                    productName: row.column("productName")?.string ?? "",
                    volume: row.column("vol")?.double ?? 0,
                    amount: row.column("amt")?.double ?? 0,
                    payMode: row.column("payMode")?.string ?? "",
                    attendant: row.column("attendant")?.string ?? "",
                    paidState: state
                )
            }
        }
    }
}
