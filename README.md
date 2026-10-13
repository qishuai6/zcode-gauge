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
| 本地绝对用量、限额估算 | 只读查询 `~/.zcode/cli/db/db.sqlite`，用「本地已用 ÷ API 百分比」反推限额（百分比在 5%~100% 才显示） |

凭证：从 `~/.zcode/v2/credentials.json` 解密（AES-256-GCM，密钥由本机用户名/家目录派生，无钥匙串授权）。ZCode 客户端刷新登录态后写回该文件，油表每次现读现解密，自动跟随。算法细节见 `notes/api-probe.md`。

## 故障排查

- **显示「离线/接口不可达」**：网络问题，或 ZCode 登录态失效——打开 ZCode 客户端重新登录即可
- **显示「凭证读取失败」**：credentials.json 结构变化或环境变量 `ZCODE_CREDENTIAL_SECRET` 被设置过，重跑 `probe/main.swift` 探针定位
- **改刷新间隔**：见上方使用说明，改完 `./build.sh`

## 目录

- `Sources/` App 源码（Swift/AppKit，零第三方依赖）
- `probe/` 数据探针（解密验证 + 接口连通性测试）
- `notes/api-probe.md` 接口与加密格式的完整调研记录
