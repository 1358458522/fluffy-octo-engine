import Foundation
import SQLServerNIO

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

struct DayAggregate {
    var count: Int = 0
    var amount: Double = 0
    var volume: Double = 0
    var firstTime: String?
    var lastTime: String?
    var shifts: [ShiftRevenue] = []
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

    // MARK: - 当日各班次营业额

    static func fetchDay(_ station: Station, date: String) async throws -> DayAggregate {
        try await withClient(station) { client in
            let sql = """
            SELECT FBusinessShiftNo AS shiftNo,
                   COUNT(*) AS cnt,
                   CAST(ISNULL(SUM(FTradeAmount), 0) AS float) AS amt,
                   CAST(ISNULL(SUM(FTradeVolume), 0) AS float) AS vol,
                   CONVERT(varchar(19), MIN(FTradeTime), 120) AS tmin,
                   CONVERT(varchar(19), MAX(FTradeTime), 120) AS tmax
            FROM TFuelTradeRecord WITH (NOLOCK)
            WHERE CONVERT(varchar(10), FBusinessDate, 120) = '\(date)'
            GROUP BY FBusinessShiftNo
            ORDER BY FBusinessShiftNo
            """

            let rows = try await client.query(sql)
            var aggregate = DayAggregate()

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
            return aggregate
        }
    }

    // MARK: - 逐笔明细

    static func fetchTrades(
        _ station: Station,
        date: String,
        shift: Int? = nil,
        limit: Int = 500
    ) async throws -> [TradeRow] {
        try await withClient(station) { client in
            var condition = "CONVERT(varchar(10), t.FBusinessDate, 120) = '\(date)'"
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
