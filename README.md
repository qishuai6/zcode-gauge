# ZCode 油表

macOS 菜单栏小工具，随时查看智谱 Coding Plan（ZCode）的 token 额度：

- **菜单栏常驻** `⚡55%`：5 小时窗口和本周额度中更紧张的剩余百分比，颜色随余量变化（杏黄 → 橙 → 红）
- **点开即看**：5 小时窗口、本周额度（进度条 + 百分比 + 重置倒计时）、重置次数、MCP 工具调用额度
- 每 60 秒自动刷新（改间隔：`Sources/AppDelegate.swift` 的 `refreshInterval`）；菜单打开时数据超 30 秒旧也会自动重拉；`⌘R` 手动刷新

## 使用

```bash
# 编译打包
./build.sh

# 启动
open build/ZCodeGauge.app
```

建议把 `build/ZCodeGauge.app` 拖到「应用程序」文件夹，再点菜单里的「开机自启」。

## 数据来源

| 数据 | 来源 |
|---|---|
| 5h / 每周百分比、重置时间 | `bigmodel.cn/api/monitor/usage/quota/limit`（ZCode 客户端同款接口） |
| 重置次数 | `zcode.z.ai/api/v1/coding-plan/reset/status` |
| 本地绝对用量 | 只读查询 `~/.zcode/cli/db/db.sqlite`（最近 5 小时 / 本周一至今的 token 数） |

凭证：从 `~/.zcode/v2/credentials.json` 解密（AES-256-GCM）。ZCode 2026-11 起默认新格式 `enc:v2:os:`——密钥是 32 字节随机串，存 macOS 钥匙串（service=`ZCode Credential Encryption`，account=credentials.json 绝对路径的 SHA256 hex），油表通过 `/usr/bin/security` 静默读取，无需授权弹窗；旧格式 `enc:v1:` 仍兼容。ZCode 客户端刷新登录态后写回该文件，油表每次现读现解密，自动跟随。算法细节见 `notes/api-probe.md`。

## 故障排查

- **显示「离线/接口不可达」**：网络问题，或 ZCode 登录态失效——打开 ZCode 客户端重新登录即可
- **显示「凭证读取失败」**：credentials.json 结构变化或环境变量 `ZCODE_CREDENTIAL_SECRET` 被设置过，重跑 `probe/main.swift` 探针定位
- **改刷新间隔**：见上方使用说明，改完 `./build.sh`

## 目录

- `Sources/` App 源码（Swift/AppKit，零第三方依赖）
- `probe/` 数据探针（解密验证 + 接口连通性测试）
- `notes/api-probe.md` 接口与加密格式的完整调研记录

## 更新日志

- **2026-11-11** 适配 ZCode 更新后的凭证新格式 `enc:v2:os:`（两接口齐报「不可达」的根因）：新版把加密密钥从「用户名/家目录派生」改为 32 字节随机串存进 macOS 钥匙串（service=`ZCode Credential Encryption`，account=credentials.json 路径的 SHA256 hex），密文多了一段 keyId（密钥 SHA256 的 hex 前 24 位）用于校验。读取钥匙串走 `/usr/bin/security` 命令行（直连 SecItemCopyMatching 会弹授权框），且密钥进程内只读一次——并发多次触发 security 子进程会偶发卡死。旧格式 `enc:v1:` 与 `*coding-plan*api-key` 兜底逻辑保留。
- **2026-10-19** 修正 5 小时窗口与本周额度对调的问题：原先按 `nextResetTime` 远近猜窗口，窗口重置时间交错时会整体显示反。现与 ZCode 客户端一致，按 `(type=TOKENS_LIMIT, unit=3, number=5)` 取 5 小时窗口、`unit=6` 取周窗口；`percentage` 是已用百分比（客户端渲染 `100 - percentage`，文案为「5 小时 Prompt 池已用 {percent}」）。同时移除本地用量反推的「限额≈」显示——本地统计口径与服务端固定窗口不一致，反推值会严重失真。
- **2026-10-19** 修复 api-key 查找写死 `bigmodel-individual-coding-plan` 导致两接口齐报「不可达」的问题：credentials.json 里 api-key 的 key 名会随计划类型变化（individual / team 等），现改为优先 individual、其余 `*coding-plan*api-key` 兜底。
- **2026-10-13** 项目发布：macOS 菜单栏实时查看智谱 Coding Plan 额度——5h 窗口 / 本周 token / 重置次数 / MCP 工具额度，60 秒自动刷新，零第三方依赖。
