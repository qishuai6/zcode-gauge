import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var snapshot: QuotaSnapshot?
    private var lastErrorMessage: String?
    private var refreshing = false
    private var rebuildPending = false   // 菜单打开期间刷完 → 关闭后再重建
    private var menuOpen = false
    private var timer: Timer?

    private let refreshInterval: TimeInterval = 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // 验收辅助：--demo-menu 启动后 4 秒自动弹出菜单（供截图）
        if CommandLine.arguments.contains("--demo-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.statusItem.button?.performClick(nil)
            }
        }
    }

    // MARK: 刷新

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        QuotaService.shared.refresh { [weak self] snap in
            guard let self else { return }
            self.refreshing = false
            self.snapshot = snap
            var errors: [String] = []
            if !snap.quotaOK { errors.append("额度接口不可达") }
            if !snap.resetOK { errors.append("重置接口不可达") }
            if !snap.localOK { errors.append("本地统计不可用") }
            self.lastErrorMessage = errors.isEmpty ? nil : errors.joined(separator: " · ")
            self.updateStatusTitle()
            if self.menuOpen {
                self.rebuildPending = true   // 等 menuDidClose 再重建，避免追踪态下改菜单
            } else {
                self.rebuildMenu()
            }
        }
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        guard let snap = snapshot else {
            button.attributedTitle = attributed("⚡--", color: .secondaryLabelColor)
            return
        }
        if let remain = snap.tightestRemaining {
            button.attributedTitle = attributed("⚡\(remain)%", color: Palette.gauge(remainingPercent: remain))
        } else {
            button.attributedTitle = attributed("⚡--", color: .secondaryLabelColor)
        }
    }

    private func attributed(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color,
        ])
    }

    // MARK: 菜单

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        // Apple 提示回调内不要改菜单结构 → 异步重建
        if rebuildPending {
            rebuildPending = false
            DispatchQueue.main.async { [weak self] in self?.rebuildMenu() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let s = snapshot, Date().timeIntervalSince(s.updatedAt) < 30 { return }
        refresh()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let header = NSMenuItem()
        header.view = HeaderView(title: "ZCode 油表",
                                 meta: metaText())
        menu.addItem(header)
        menu.addItem(.separator())

        if let snap = snapshot {
            if let f = snap.fiveHour {
                let card = QuotaCardView(title: "5 小时窗口")
                card.update(
                    usedPercent: f.usedPercent,
                    remaining: max(0, 100 - Int(f.usedPercent.rounded())),
                    resetText: Fmt.countdown(until: f.nextReset),
                    value: String(format: "已用 %.0f%% · 剩余 %.0f%%", f.usedPercent, 100 - f.usedPercent),
                    sub: localText(tokens: snap.localTokens5h, est: snap.est5hLimit)
                )
                menu.addItem(item(with: card))
            }
            if let w = snap.weekly {
                let card = QuotaCardView(title: "本周额度")
                card.update(
                    usedPercent: w.usedPercent,
                    remaining: max(0, 100 - Int(w.usedPercent.rounded())),
                    resetText: Fmt.resetDate(w.nextReset),
                    value: String(format: "已用 %.0f%% · 剩余 %.0f%%", w.usedPercent, 100 - w.usedPercent),
                    sub: localText(tokens: snap.localTokensWeek, est: snap.estWeekLimit)
                )
                menu.addItem(item(with: card))
            }
            menu.addItem(item(with: RowView(
                left: "重置次数",
                right: resetText(snap),
                rightColor: Palette.apricotText
            )))
            if let tool = snap.tool {
                menu.addItem(item(with: RowView(
                    left: "MCP 工具调用",
                    right: "\(tool.used) / \(tool.total) 次"
                )))
            }
        } else {
            let row = NSTextField(labelWithString: lastErrorMessage ?? "正在获取数据…")
            row.font = .systemFont(ofSize: 11)
            row.textColor = .secondaryLabelColor
            row.frame = NSRect(x: 16, y: 4, width: 284, height: 16)
            let holder = NSView(frame: NSRect(x: 0, y: 0, width: QuotaCardView.width, height: 24))
            holder.addSubview(row)
            menu.addItem(item(with: holder))
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshAction), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let login = NSMenuItem(title: "开机自启", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "退出 ZCode 油表", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(with view: NSView) -> NSMenuItem {
        let i = NSMenuItem()
        i.view = view
        return i
    }

    private func metaText() -> String {
        guard let snap = snapshot else { return "获取中…" }
        var meta = "Pro · \(Fmt.time(snap.updatedAt)) 更新"
        if let err = lastErrorMessage { meta = err + " · " + meta }
        return meta
    }

    private func resetText(_ snap: QuotaSnapshot) -> String {
        switch (snap.resets5h, snap.resetsWeek) {
        case let (a?, b?): return "5小时 ×\(a) · 每周 ×\(b)"
        case let (a?, nil): return "5小时 ×\(a)"
        case let (nil, b?): return "每周 ×\(b)"
        default: return "暂不可用"
        }
    }

    private func localText(tokens: Int64?, est: Int64?) -> String {
        var parts: [String] = []
        if let tokens { parts.append("本地 \(Fmt.tokens(tokens))") }
        if let est { parts.append("限额≈\(Fmt.tokens(est))") }
        return parts.joined(separator: " · ")
    }

    // MARK: 动作

    @objc private func refreshAction() {
        refresh()
    }

    @objc private func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            default:
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "开机自启设置失败"
            alert.informativeText = "\(error.localizedDescription)\n\n提示：把 App 拖到「应用程序」文件夹后再试。"
            alert.runModal()
        }
        rebuildMenu()
    }
}
