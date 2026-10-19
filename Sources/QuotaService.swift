import Foundation
import CryptoKit

// MARK: - 数据模型

struct LimitWindow {
    let usedPercent: Double   // API 返回的已用百分比
    let nextReset: Date
}

struct ToolQuota {
    let total: Int
    let used: Int
    var remaining: Int { max(0, total - used) }
}

struct QuotaSnapshot {
    var fiveHour: LimitWindow?
    var weekly: LimitWindow?
    var tool: ToolQuota?
    var resets5h: Int?
    var resetsWeek: Int?
    var localTokens5h: Int64?
    var localTokensWeek: Int64?
    var updatedAt = Date()
    var quotaOK = false       // quota/limit 是否成功
    var resetOK = false       // reset/status 是否成功
    var localOK = false

    /// 菜单栏数字：两个窗口中更紧张的剩余百分比
    var tightestRemaining: Int? {
        var worst: Double?
        if let f = fiveHour { worst = f.usedPercent }
        if let w = weekly { worst = max(worst ?? -1, w.usedPercent) }
        guard let worst else { return nil }
        return max(0, Int((100 - worst).rounded()))
    }
}

// MARK: - 凭证解密（AES-256-GCM，enc:v1:iv.tag.ciphertext）

enum Credentials {
    static let prefix = "enc:v1:"

    static func load() -> (apiKey: String, jwt: String, oauth: String)? {
        let path = NSString(string: "~/.zcode/v2/credentials.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        let env = ProcessInfo.processInfo.environment
        let secret = env["ZCODE_CREDENTIAL_SECRET"]
            ?? "zcode-credential-fallback:darwin:\(NSHomeDirectory()):\(NSUserName())"
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))

        func decrypt(_ s: String) -> String? {
            guard s.hasPrefix(prefix) else { return s }
            let parts = s.dropFirst(prefix.count).components(separatedBy: ".")
            guard parts.count == 3,
                  let iv = b64url(parts[0]), let tag = b64url(parts[1]), let ct = b64url(parts[2]),
                  iv.count == 12, tag.count == 16 else { return nil }
            guard let box = try? AES.GCM.SealedBox(combined: iv + ct + tag),
                  let plain = try? AES.GCM.open(box, using: key) else { return nil }
            return String(data: plain, encoding: .utf8)
        }

        var apiKey: String?
        var anyPlanApiKey: String?   // 2026-10-19 起 api-key 挂在 team 计划 key 下，individual 匹配不到时兜底
        var jwt: String?
        var oauth: String?
        for (k, v) in json {
            guard let plain = decrypt(v) else { continue }
            if k.contains("coding-plan") && k.contains("api-key") {
                if k.contains("bigmodel-individual-coding-plan") { apiKey = plain }
                else { anyPlanApiKey = anyPlanApiKey ?? plain }
            }
            if k == "zcodejwttoken" { jwt = plain }
            if k == "oauth:bigmodel:access_token" { oauth = plain }
        }
        guard let apiKey = apiKey ?? anyPlanApiKey, let jwt, let oauth else { return nil }
        return (apiKey, jwt, oauth)
    }

    private static func b64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

// MARK: - 额度服务

final class QuotaService {
    static let shared = QuotaService()
    private let session = URLSession(configuration: .ephemeral)

    func refresh(_ done: @escaping (QuotaSnapshot) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var snap = QuotaSnapshot()
            let group = DispatchGroup()

            group.enter()
            self.fetchQuotaLimit { snap.quotaOK = $0; snap.fiveHour = $1?.0; snap.weekly = $1?.1; snap.tool = $1?.2; group.leave() }

            group.enter()
            self.fetchResetStatus { snap.resetOK = $0; snap.resets5h = $1?.0; snap.resetsWeek = $1?.1; group.leave() }

            group.enter()
            self.fetchLocal { snap.localOK = $0; snap.localTokens5h = $1?.0; snap.localTokensWeek = $1?.1; group.leave() }

            group.wait()

            // 不做限额反推：本地按「最近 5 小时 / 本周一至今」统计，服务端是固定 5h 窗口与周周期，
            // 两者口径不同，反推出来的限额会严重失真（曾算出 1.29 亿这种数字），只展示本地绝对量

            DispatchQueue.main.async { done(snap) }
        }
    }

    private func get(_ url: String, headers: [String: String], _ done: @escaping (Int, Data?) -> Void) {
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = 15
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        session.dataTask(with: req) { d, r, _ in
            done((r as? HTTPURLResponse)?.statusCode ?? -1, d)
        }.resume()
    }

    private func fetchQuotaLimit(_ done: @escaping (Bool, (LimitWindow, LimitWindow, ToolQuota?)?) -> Void) {
        guard let cred = Credentials.load() else { done(false, nil); return }
        get("https://bigmodel.cn/api/monitor/usage/quota/limit",
            headers: ["authorization": cred.apiKey]) { code, data in
            guard code == 200, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ((obj["code"] as? Int) == 200 || (obj["code"] as? Int) == 0),
                  let limits = (obj["data"] as? [String: Any])?["limits"] as? [[String: Any]] else {
                done(false, nil); return
            }
            // 窗口识别与 ZCode 客户端一致：TOKENS_LIMIT 按 (unit, number) 精确匹配
            // 5h 窗口 = unit 3 / number 5，周窗口 = unit 6；percentage 是已用百分比
            // （客户端渲染时做 100 - percentage，文案为「5 小时 Prompt 池已用 {percent}」）
            // 早期版本按 nextResetTime 远近猜窗口，窗口时间跨过来时会整体对调，故弃用
            var fiveHour: (pct: Double, reset: Date)?
            var weekly: (pct: Double, reset: Date)?
            var fallback: [(pct: Double, reset: Date)] = []
            var tool: ToolQuota?
            for l in limits {
                let type = l["type"] as? String ?? ""
                let resetMs = (l["nextResetTime"] as? Double) ?? 0
                let reset = Date(timeIntervalSince1970: resetMs / 1000)
                guard let raw = l["percentage"] as? Double ?? (l["percentage"] as? Int).map(Double.init) else { continue }
                if type == "TOKENS_LIMIT" {
                    let unit = (l["unit"] as? Int) ?? (l["unit"] as? Double).map(Int.init) ?? -1
                    let number = (l["number"] as? Int) ?? (l["number"] as? Double).map(Int.init) ?? -1
                    let w = (pct: raw, reset: reset)
                    if unit == 3 && number == 5 { fiveHour = w }
                    else if unit == 6 { weekly = w }
                    else { fallback.append(w) }
                } else if type == "TIME_LIMIT",
                          let total = (l["usage"] as? Int) ?? (l["usage"] as? Double).map(Int.init) {
                    let used = (l["currentValue"] as? Int) ?? (l["currentValue"] as? Double).map(Int.init) ?? 0
                    tool = ToolQuota(total: total, used: used)
                }
            }
            // unit 字段缺失或结构变动时退回旧规则，按重置时间远近兜底
            if fiveHour == nil || weekly == nil {
                let all = fallback + [fiveHour, weekly].compactMap { $0 }
                if fiveHour == nil, let near = all.min(by: { $0.reset < $1.reset }) { fiveHour = near }
                if weekly == nil {
                    let rest = all.filter { $0.reset != fiveHour?.reset }
                    if let far = rest.max(by: { $0.reset < $1.reset }) { weekly = far }
                }
            }
            guard let f = fiveHour, let w = weekly else { done(false, nil); return }
            done(true, (LimitWindow(usedPercent: f.pct, nextReset: f.reset),
                        LimitWindow(usedPercent: w.pct, nextReset: w.reset),
                        tool))
        }
    }

    private func fetchResetStatus(_ done: @escaping (Bool, (Int, Int)?) -> Void) {
        guard let cred = Credentials.load() else { done(false, nil); return }
        get("https://zcode.z.ai/api/v1/coding-plan/reset/status", headers: [
            "Authorization": "Bearer " + cred.jwt,
            "X-Bigmodel-Authorization": "Bearer " + cred.oauth,
            "Bigmodel-Target-Type": "PERSONAL",
        ]) { code, data in
            guard code == 200, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["code"] as? Int) == 0,
                  let d = obj["data"] as? [String: Any] else {
                done(false, nil); return
            }
            let n5 = (d["available_five_hour_resets"] as? [[String: Any]])?.count
            let nw = (d["available_week_resets"] as? [[String: Any]])?.count
            guard let n5, let nw else { done(false, nil); return }
            done(true, (n5, nw))
        }
    }

    private func fetchLocal(_ done: @escaping (Bool, (Int64, Int64)?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let now = Date()
            let since5hMs = Int64(now.addingTimeInterval(-5 * 3600).timeIntervalSince1970 * 1000)
            var cal = Calendar(identifier: .iso8601)
            cal.firstWeekday = 2 // 周一为一周起点
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let weekStart = cal.startOfDay(for: cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!)
            let t5 = LocalUsage.tokens(sinceEpochMs: since5hMs)
            let tw = LocalUsage.tokens(sinceEpochMs: Int64(weekStart.timeIntervalSince1970 * 1000))
            guard let t5, let tw else { done(false, nil); return }
            done(true, (t5, tw))
        }
    }
}
