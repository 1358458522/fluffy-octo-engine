import Foundation
import SQLServerKit

/// 取数链路约定（自签真机稳定版）：
/// 1) 只允许「单站串行」查询 —— 上层不并发，任何批量都由上层逐个 await；
/// 2) 站点连接在本次运行内复用，不再每次查询新建/拆除线程池；
/// 3) TLS 统一信任服务端证书（云库为自签证书），严格校验会握手失败；
/// 4) 每一步都写 Diag 日志，真机崩溃后可回看崩溃报告里的最后阶段。
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

    // MARK: - 建连（单站串行 + 连接复用 + 全程留痕）

    /// 站点连接缓存：同一站点在一次运行内复用长连接，避免每次查询都新建/拆除线程池。
    /// 新方案只做串行查询（一次最多一个站点），缓存上限 3 个，超出按最久未用淘汰。
    private static let cacheLock = NSLock()
    private static var clients: [String: SQLServerClient] = [:]
    private static var clientOrder: [String] = []
    private static let clientLimit = 3

    private static func clientKey(_ station: Station) -> String {
        let hp = station.hostPort
        return "\(hp.host):\(hp.port)/\(station.db)/\(station.user)/\(station.useTLS ? "tls" : "plain")"
    }

    /// 站点连接配置。
    /// 站点云库用的是自签证书，必须信任服务端证书（等价 SSMS / JDBC 的 trustServerCertificate=true），
    /// 严格校验证书会导致握手失败；同时关闭 TNIR，避免数值 IP 场景下多余的名字解析。
    private static func configuration(for station: Station, host: String) -> SQLServerClient.Configuration {
        SQLServerClient.Configuration(
            hostname: host,
            port: station.hostPort.port,
            database: station.db.isEmpty ? "moms" : station.db,
            authentication: .sqlPassword(username: station.user, password: station.pwd),
            tlsEnabled: station.useTLS,
            trustServerCertificate: true,
            encryptionMode: .optional,
            transparentNetworkIPResolution: false
        )
    }

    private static func cachedClient(_ key: String) -> SQLServerClient? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return clients[key]
    }

    private static func store(key: String, client: SQLServerClient) {
        cacheLock.lock()
        clients[key] = client
        clientOrder.removeAll { $0 == key }
        clientOrder.append(key)
        var evicted: [SQLServerClient] = []
        while clientOrder.count > clientLimit {
            let oldest = clientOrder.removeFirst()
            if let dead = clients.removeValue(forKey: oldest) { evicted.append(dead) }
        }
        cacheLock.unlock()
        // 淘汰的连接放到后台关闭，不阻塞当前查询
        for dead in evicted {
            Task.detached { try? await dead.shutdownGracefully() }
        }
    }

    private static func dropClient(_ key: String) {
        cacheLock.lock()
        let dead = clients.removeValue(forKey: key)
        clientOrder.removeAll { $0 == key }
        cacheLock.unlock()
        if let dead {
            Task.detached { try? await dead.shutdownGracefully() }
        }
    }

    private static func withClient<T>(
        _ station: Station,
        _ body: (SQLServerClient) async throws -> T
    ) async throws -> T {
        let host = station.hostPort.host
        guard !host.isEmpty else { throw DBError.emptyServer }
        let key = clientKey(station)

        if let cached = cachedClient(key) {
            Diag.log("复用连接 \(key)")
            do {
                return try await body(cached)
            } catch {
                Diag.log("查询失败，丢弃该站连接：\(error)")
                dropClient(key)
                throw error
            }
        }

        Diag.log("新建连接 \(key)（TLS \(station.useTLS ? "开" : "关")）")
        var client: SQLServerClient
        do {
            client = try await SQLServerClient.connect(configuration: configuration(for: station, host: host))
        } catch {
            // 兜底：若该站误开了加密连接而建连失败，自动降级为不加密再试一次
            //（iOS 上加密连接不可用，云库本身不要求加密）
            guard station.useTLS else {
                Diag.log("建连失败 \(key)：\(error)")
                throw error
            }
            Diag.log("加密建连失败，自动降级为不加密重试：\(error)")
            var plain = station
            plain.useTLS = false
            do {
                client = try await SQLServerClient.connect(configuration: configuration(for: plain, host: host))
                Diag.log("降级不加密后建连成功 \(key)")
            } catch {
                Diag.log("建连失败 \(key)：\(error)")
                throw error
            }
        }
        Diag.log("建连成功 \(key)")
        store(key: key, client: client)

        do {
            return try await body(client)
        } catch {
            Diag.log("查询失败，丢弃该站连接：\(error)")
            dropClient(key)
            throw error
        }
    }

    // MARK: - 诊断探针（「诊断」页使用：一次只测一项）

    enum ProbeMode: String, CaseIterable {
        case plain = "不加密（TLS 关）"
        case trust = "加密 + 信任服务端证书"
        case strict = "加密 + 严格校验证书"

        /// 诊断页展示用标题：TLS 两项在 iOS 真机上可能闪退，明确标注提醒
        var title: String {
            switch self {
            case .plain: return rawValue
            case .trust, .strict: return rawValue + "（iOS 上会闪退，仅作对比）"
            }
        }
    }

    /// 单站点连通性探针：建连 + SELECT @@VERSION，返回可直接展示的结论
    static func probe(_ station: Station, mode: ProbeMode) async -> String {
        let host = station.hostPort.host
        guard !host.isEmpty else { return "❌ 该站点未配置云库地址" }

        let tls: SQLServerTLSConfiguration?
        switch mode {
        case .plain: tls = nil
        case .trust: tls = .trustingServerCertificate
        case .strict: tls = .clientDefault
        }

        Diag.log("探针开始：\(station.name) / \(mode.rawValue)")
        let configuration = SQLServerClient.Configuration(
            hostname: host,
            port: station.hostPort.port,
            database: station.db.isEmpty ? "moms" : station.db,
            authentication: .sqlPassword(username: station.user, password: station.pwd),
            tlsConfiguration: tls,
            encryptionMode: .optional,
            transparentNetworkIPResolution: false
        )

        do {
            let client = try await SQLServerClient.connect(configuration: configuration)
            Diag.log("探针建连成功，执行 SELECT @@VERSION")
            let rows = try await client.query("SELECT @@VERSION AS v")
            let version = (rows.first?.column("v")?.string ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            try? await client.shutdownGracefully()
            Diag.log("探针成功：\(mode.rawValue)")
            return "✅ \(mode.rawValue)：连通\n第 \(version.prefix(100))"
        } catch {
            Diag.log("探针失败：\(mode.rawValue)：\(error)")
            return "❌ \(mode.rawValue)：失败\n\(error)"
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

            Diag.log("查询: 班次汇总 \(date)")
            let rows = try await client.query(sql)
            Diag.log("查询: 班次汇总返回 \(rows.count) 行")

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
            Diag.log("查询: 按油品汇总")
            aggregate.products = await productStats(client, date: date)
            Diag.log("查询: 按支付方式汇总")
            aggregate.pays = await payStats(client, date: date)
            // 班次时段模板（交班判定使用）
            Diag.log("查询: 班次时段模板")
            aggregate.template = await shiftTemplate(client, date: date)
            Diag.log("查询: 当日取数完成")
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

            Diag.log("查询: 逐笔明细 \(date) 班次\(shift.map(String.init) ?? "全部")")
            let rows = try await client.query(sql)
            Diag.log("查询: 逐笔明细返回 \(rows.count) 行")
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
