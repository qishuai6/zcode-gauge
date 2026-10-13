import Foundation
import CryptoKit

// ZCode credentials.json 解密探针
// 格式: enc:v1:<b64url(iv)>.<b64url(tag)>.<b64url(ciphertext)>  AES-256-GCM
// 密钥: sha256(ZCODE_CREDENTIAL_SECRET 或 fallback 字符串)

func b64urlDecode(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
}

let env = ProcessInfo.processInfo.environment
let secret = env["ZCODE_CREDENTIAL_SECRET"]
    ?? "zcode-credential-fallback:darwin:\(NSHomeDirectory()):\(NSUserName())"
print("secret 来源: \(env["ZCODE_CREDENTIAL_SECRET"] != nil ? "环境变量" : "默认 fallback")")
print("secret 指纹: \(secret.prefix(12))... len=\(secret.count)")
let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))

func decrypt(_ s: String) throws -> String {
    guard s.hasPrefix("enc:v1:") else { return s }
    let parts = s.dropFirst("enc:v1:".count).components(separatedBy: ".")
    guard parts.count == 3, let iv = b64urlDecode(parts[0]),
          let tag = b64urlDecode(parts[1]), let ct = b64urlDecode(parts[2]),
          iv.count == 12, tag.count == 16 else {
        throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "密文格式非法"])
    }
    let box = try AES.GCM.SealedBox(combined: iv + ct + tag)
    let plain = try AES.GCM.open(box, using: key)
    return String(data: plain, encoding: .utf8) ?? ""
}

let credPath = NSString(string: "~/.zcode/v2/credentials.json").expandingTildeInPath
let jsonData = try Data(contentsOf: URL(fileURLWithPath: credPath))
let creds = try JSONSerialization.jsonObject(with: jsonData) as! [String: String]

var tokens: [String: String] = [:]
print("\n== 解密结果 ==")
for (k, v) in creds.sorted(by: { $0.key < $1.key }) {
    do {
        let plain = try decrypt(v)
        let interesting = k.hasPrefix("zcodejwttoken") || k.hasPrefix("oauth:")
            || k.contains("api-key") || k.hasPrefix("oauth:active_provider")
        if interesting { tokens[k] = plain }
        print("OK   \(k)  len=\(plain.count) head=\(plain.prefix(6))…")
    } catch {
        print("FAIL \(k): \(error.localizedDescription)")
    }
}

func httpGET(url: String, headers: [String: String]) -> (Int, String) {
    var req = URLRequest(url: URL(string: url)!)
    req.timeoutInterval = 15
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    let sem = DispatchSemaphore(value: 0)
    var result = (0, "")
    URLSession.shared.dataTask(with: req) { d, r, e in
        defer { sem.signal() }
        if let e = e { result = (-1, "ERROR: \(e.localizedDescription)"); return }
        let http = r as! HTTPURLResponse
        result = (http.statusCode, String(data: d ?? Data(), encoding: .utf8) ?? "<binary>")
    }.resume()
    sem.wait()
    return result
}

func fingerprint(_ s: String) -> String { String(s.prefix(8)) + "…len\(s.count)" }

print("\n== 接口 1: bigmodel quota/limit ==")
let apiKeyIndiv = tokens.first { $0.key.contains("bigmodel-individual-coding-plan") && $0.key.contains("api-key") }?.value
let apiKeyTeam = tokens.first { $0.key.contains("bigmodel-team-coding-plan") && $0.key.contains("api-key") }?.value
let oauthToken = tokens["oauth:bigmodel:access_token"]

for (label, cred) in [("individual api-key", apiKeyIndiv), ("team api-key", apiKeyTeam), ("oauth access_token", oauthToken)] {
    guard let cred = cred else { print("[\(label)] 无凭证，跳过"); continue }
    for prefix in ["", "Bearer "] {
        let (code, body) = httpGET(url: "https://bigmodel.cn/api/monitor/usage/quota/limit",
                                   headers: ["authorization": prefix + cred])
        print("\n[\(label) | authorization='\(prefix.isEmpty ? "裸值" : "Bearer")' → HTTP \(code)]")
        print(body.prefix(2500))
        if code == 200 { break }
    }
}

print("\n== 接口 2: zcode reset/status ==")
if let jwt = tokens["zcodejwttoken"], let oauth = oauthToken {
    let (code, body) = httpGET(url: "https://zcode.z.ai/api/v1/coding-plan/reset/status", headers: [
        "Authorization": "Bearer " + jwt,
        "X-Bigmodel-Authorization": "Bearer " + oauth,
        "Bigmodel-Target-Type": "PERSONAL",
    ])
    print("[HTTP \(code)]")
    print(body.prefix(2500))
} else {
    print("缺 zcodejwttoken 或 oauth token")
    for k in tokens.keys { print("  可用: \(k)") }
}

print("\n== 凭证指纹（供报告用，非明文）==")
print("individual api-key: \(apiKeyIndiv.map(fingerprint) ?? "无")")
print("zcodejwttoken: \(tokens["zcodejwttoken"].map(fingerprint) ?? "无")")
print("oauth token: \(oauthToken.map(fingerprint) ?? "无")")
