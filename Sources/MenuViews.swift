import AppKit

// MARK: - 颜色（Rams 杏黄系，深浅色菜单栏自适应）

enum Palette {
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(deviceRed: r, green: g, blue: b, alpha: 1)
    }

    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func gauge(remainingPercent: Int) -> NSColor {
        switch remainingPercent {
        case ..<10:  return dynamic(dark: rgb(0.96, 0.36, 0.31), light: rgb(0.78, 0.20, 0.15))
        case ..<25:  return dynamic(dark: rgb(0.95, 0.48, 0.20), light: rgb(0.77, 0.34, 0.10))
        default:     return dynamic(dark: rgb(0.95, 0.66, 0.30), light: rgb(0.78, 0.49, 0.13)) // 杏黄
        }
    }

    static let apricotText = dynamic(dark: rgb(0.95, 0.70, 0.35), light: rgb(0.72, 0.46, 0.10))
}

// MARK: - 格式化

enum Fmt {
    static func countdown(until date: Date, now: Date = Date()) -> String {
        let s = max(0, date.timeIntervalSince(now))
        if s < 60 { return "即将重置" }
        let m = Int(s / 60)
        if m < 60 { return "\(m)分钟后重置" }
        let h = m / 60
        if h < 24 { return "\(h)小时\(m % 60)分后重置" }
        return "\(h / 24)天\(h % 24)小时后重置"
    }

    static func resetDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 E HH:mm"
        return f.string(from: date) + " 重置"
    }

    /// 中文万进制：51249066 → 5,125万
    static func tokens(_ n: Int64) -> String {
        switch n {
        case ..<10_000: return NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        case ..<100_000_000: return String(format: "%@万", NumberFormatter.localizedString(from: NSNumber(value: Int((Double(n) / 10_000).rounded())), number: .decimal))
        default: return String(format: "%.2f亿", Double(n) / 100_000_000)
        }
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - 额度卡片（菜单内自绘）

final class QuotaCardView: NSView {
    static let width: CGFloat = 316
    static let height: CGFloat = 68

    private let titleLabel = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")
    private let barBG = NSView()
    private let barFill = NSView()
    private let valueLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private var fillRatio: CGFloat = 0
    private var fillColor: NSColor = Palette.gauge(remainingPercent: 100)

    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 16, y: Self.height - 20, width: 150, height: 15)
        addSubview(titleLabel)
        titleLabel.stringValue = title

        rightLabel.font = .systemFont(ofSize: 10)
        rightLabel.textColor = .tertiaryLabelColor
        rightLabel.alignment = .right
        rightLabel.frame = NSRect(x: Self.width - 186, y: Self.height - 20, width: 170, height: 15)
        addSubview(rightLabel)

        let barY: CGFloat = Self.height - 36
        barBG.wantsLayer = true
        barBG.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        barBG.layer?.cornerRadius = 3
        barBG.frame = NSRect(x: 16, y: barY, width: Self.width - 32, height: 6)
        addSubview(barBG)

        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 3
        barFill.frame = barBG.frame.insetBy(dx: 0, dy: 0)
        barFill.frame.size.width = 0
        addSubview(barFill)

        valueLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.frame = NSRect(x: 16, y: 8, width: 180, height: 17)
        addSubview(valueLabel)

        subLabel.font = .systemFont(ofSize: 10)
        subLabel.textColor = .tertiaryLabelColor
        subLabel.alignment = .right
        subLabel.frame = NSRect(x: Self.width - 196, y: 9, width: 180, height: 15)
        addSubview(subLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(usedPercent: Double, remaining: Int, resetText: String, value: String, sub: String) {
        rightLabel.stringValue = resetText
        rightLabel.textColor = remaining <= 10 ? .systemRed : .tertiaryLabelColor
        fillRatio = CGFloat(min(1, max(0, usedPercent / 100)))
        fillColor = Palette.gauge(remainingPercent: remaining)
        barFill.layer?.backgroundColor = fillColor.cgColor
        valueLabel.stringValue = value
        subLabel.stringValue = sub
        needsLayout = true
    }

    override func layout() {
        super.layout()
        barFill.frame = NSRect(x: 16, y: barBG.frame.origin.y,
                               width: (Self.width - 32) * fillRatio, height: 6)
    }
}

// MARK: - 头部（标题 + 更新时间）

final class HeaderView: NSView {
    static let height: CGFloat = 30

    init(title: String, meta: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: QuotaCardView.width, height: Self.height))
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .bold)
        t.textColor = Palette.apricotText
        t.frame = NSRect(x: 16, y: 7, width: 150, height: 17)
        addSubview(t)

        let m = NSTextField(labelWithString: meta)
        m.font = .systemFont(ofSize: 10)
        m.textColor = .tertiaryLabelColor
        m.alignment = .right
        m.frame = NSRect(x: QuotaCardView.width - 206, y: 8, width: 190, height: 15)
        addSubview(m)
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 菜单行（普通文字行，右列对齐）

final class RowView: NSView {
    static let height: CGFloat = 22

    init(left: String, right: String, rightColor: NSColor = .secondaryLabelColor) {
        super.init(frame: NSRect(x: 0, y: 0, width: QuotaCardView.width, height: Self.height))
        let l = NSTextField(labelWithString: left)
        l.font = .systemFont(ofSize: 11.5)
        l.textColor = .labelColor
        l.frame = NSRect(x: 16, y: 3, width: 190, height: 16)
        addSubview(l)

        let r = NSTextField(labelWithString: right)
        r.font = .systemFont(ofSize: 11.5, weight: .medium)
        r.textColor = rightColor
        r.alignment = .right
        r.frame = NSRect(x: QuotaCardView.width - 170, y: 3, width: 154, height: 16)
        addSubview(r)
    }

    required init?(coder: NSCoder) { fatalError() }
}
