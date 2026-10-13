# ZCode 油表 · 数据源探针报告（2026-10-12 实测通过）

## 凭证解密（已验证，无需钥匙串授权）

- 文件：`~/.zcode/v2/credentials.json`，所有值为 `enc:v1:<b64url(iv)>.<b64url(tag)>.<b64url(ciphertext)>`
- 算法：AES-256-GCM（IV 12 字节，tag 16 字节）
- 密钥：`sha256(secret)`，secret = 环境变量 `ZCODE_CREDENTIAL_SECRET`，缺省 fallback：
  `zcode-credential-fallback:darwin:<HOME>:<USERNAME>`（如 `zcode-credential-fallback:darwin:/Users/qishuai:qishuai`）
- 所需字段（实测均能解密）：
  - `account-provider:coding-plan:account:bigmodel-individual-coding-plan:account:<账号ID>:api-key`（bigmodel API key，调 quota/limit）
  - `zcodejwttoken` + `oauth:bigmodel:access_token`（调 reset/status 双 token）
  - 客户端刷新登录态后会写回此文件，App 每次现读现解密即可跟随刷新

## 接口 1：额度（quota/limit）

`GET https://bigmodel.cn/api/monitor/usage/quota/limit`
请求头：`authorization: <api-key 裸值>`（不带 Bearer；实测裸值/Bearer/oauth token 都返回 200，取 api-key 裸值）

响应（2026-10-12 实测，level=pro）：

```json
{"code":200,"msg":"操作成功","data":{"limits":[
  {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"nextResetTime":1791829535496},
  {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":45,"nextResetTime":1792395327999},
  {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":385,"remaining":615,
   "percentage":38,"nextResetTime":1792123560991,
   "usageDetails":[{"modelCode":"search-prime","usage":323},{"modelCode":"web-reader","usage":62},{"modelCode":"zread","usage":0}]}
],"level":"pro"},"success":true}
```

字段语义（实测推断）：
- `TOKENS_LIMIT unit=3 number=5` → **5 小时窗口**，`percentage`=已用百分比（服务端只给百分比，无绝对 token 数）
- `TOKENS_LIMIT unit=6 number=1` → **每周窗口**
- `TIME_LIMIT` → MCP 工具调用次数（usage=总额度，currentValue=已用，remaining=剩余），非主 token
- `nextResetTime`：epoch 毫秒
- **识别策略（抗数组顺序变化）**：weekly = TOKENS_LIMIT 中 nextResetTime 最大者；fiveHour = nextResetTime 最小者

## 接口 2：重置次数（reset/status）

`GET https://zcode.z.ai/api/v1/coding-plan/reset/status`
请求头（三件套）：
- `Authorization: Bearer <zcodejwttoken>`
- `X-Bigmodel-Authorization: Bearer <oauth:bigmodel:access_token>`
- `Bigmodel-Target-Type: PERSONAL`

响应（2026-10-12 实测 HTTP 200）：

```json
{"code":0,"msg":"success","data":{
  "available_five_hour_resets":[{"expire_at":1791815810000},{"expire_at":1793156453000}],
  "available_week_resets":[{"expire_at":...}×4],
  "latest_five_hour_reset_history":{"used_at":1791792486000},
  "latest_week_reset_history":{"used_at":1791790528000},
  "has_unread_history":false}}
```

- 5h 重置剩余次数 = `available_five_hour_resets.length`（当前 ×2），周重置 = `available_week_resets.length`（当前 ×4）

## 接口 3（兜底）：本地 SQLite

`~/.zcode/cli/db/db.sqlite`（WAL，只读打开）表 `model_usage`：
- 过滤 `provider_id = 'account:bigmodel-individual-coding-plan'`
- 绝对 token 量：`SUM(computed_total_tokens)`，时间用 `started_at`（epoch 毫秒）
- 用途：① 显示近 5h / 本周的绝对用量 ② API 失败时的离线兜底 ③ 用 `本地已用 ÷ API百分比` 反推估算限额（仅 5%<percentage<100% 时展示）

## 已知风险

- `quota/limit` 的 limits 数组结构可能随版本变化 → 已用语义识别而非硬编码索引
- JWT 会过期 → 客户端会自动刷新并写回 credentials.json，App 现读现解密不受影响
- 估算限额只在百分比处于中间区间时显示，避免小样本误差
