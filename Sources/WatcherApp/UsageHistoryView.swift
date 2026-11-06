import SwiftUI
import WatcherCore

struct UsageHistoryView: View {
    @ObservedObject var model: WatcherModel
    @Environment(\.colorScheme) private var scheme
    private var secondary: Color { PanelStyle.secondary(scheme) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("历史用量").font(.system(size: 17, weight: .semibold))
                    Text("这台 Mac").font(.system(size: 11)).foregroundStyle(secondary)
                    Spacer()
                    Picker("年份", selection: Binding(get: { model.historyYear }, set: { model.selectHistoryYear($0) })) {
                        ForEach(model.historyYears, id: \.self) { Text(String($0)).tag($0) }
                    }.labelsHidden().frame(width: 88)
                }
                HStack {
                    Picker("Agent", selection: Binding(get: { model.historyScope }, set: { model.selectHistoryScope($0) })) {
                        Text("合计").tag(AgentProvider?.none)
                        Text("Codex").tag(AgentProvider?.some(.codex))
                        Text("Claude").tag(AgentProvider?.some(.claude))
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 250)
                    Spacer()
                    Text(model.historyLoading ? "读取缓存中" : model.historyPartial ? "部分统计 · 已索引记录" : "已索引本机记录")
                        .font(.system(size: 10)).foregroundStyle(secondary)
                }
                HStack(spacing: 40) {
                    metric("全年 token", model.historyLoading ? "—" : compactNumber(model.historyMap.total))
                    metric("用量天数", "\(model.historyMap.activeDays)")
                    metric("单日最高", compactNumber(model.historyMap.peak))
                    Spacer()
                }.padding(.vertical, 3)
                HistoryHeatmap(map: model.historyMap, calendar: model.historyCalendar, selected: $model.historySelection)
                    .frame(height: 112)
                HStack(spacing: 5) {
                    Text("每格一天 · 悬停看数值，点击看明细")
                    Spacer()
                    Text("少")
                    ForEach(0..<5) { level in RoundedRectangle(cornerRadius: 2).fill(HistoryHeatmap.colors(dark: scheme == .dark)[level]).frame(width: 10, height: 10) }
                    Text("多")
                }.font(.system(size: 11)).foregroundStyle(secondary)
                Divider()
                HStack {
                    DatePicker("日期", selection: $model.historySelection, in: model.historyBounds, displayedComponents: .date).labelsHidden().fixedSize()
                    Spacer()
                    if model.selectedHistoryDay.records > 0 {
                        Text(model.selectedHistoryDay.tokens.total.formatted() + " tok").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    } else { Text("无已索引用量记录").font(.system(size: 12)).foregroundStyle(secondary) }
                }
                HStack(alignment: .top, spacing: 25) {
                    VStack(spacing: 10) {
                        ForEach(model.historyScope.map { [$0] } ?? AgentProvider.allCases, id: \.self) { provider in
                            HStack(spacing: 7) {
                                AgentIcon(provider: provider, size: 18)
                                Text(provider == .codex ? "Codex" : "Claude").foregroundStyle(secondary)
                                Spacer()
                                Text(compactNumber(model.selectedHistoryUsage(provider).tokens.total)).monospacedDigit()
                            }
                        }
                    }.frame(width: 180)
                    VStack(spacing: 10) {
                        detail("输入合计", model.selectedHistoryDay.tokens.input)
                        detail("输出合计", model.selectedHistoryDay.tokens.output)
                    }.frame(maxWidth: .infinity)
                    VStack(spacing: 10) {
                        detail("缓存读取¹", model.selectedHistoryDay.tokens.cached)
                        detail("缓存写入¹", model.selectedHistoryDay.tokens.cacheWrite)
                    }.frame(maxWidth: .infinity)
                }.font(.system(size: 11))
                HStack {
                    Text("¹ 缓存已含在输入中。颜色按当前视图非零日期分档。")
                    Spacer()
                    Text("每小时更新 · 手动刷新可立即更新")
                }.font(.system(size: 11)).foregroundStyle(secondary)
                if let error = model.historyError { Text(error).font(.system(size: 11)).foregroundStyle(secondary) }
            }.padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 3)
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 10)).foregroundStyle(secondary); Text(value).font(.system(size: 23, weight: .medium)).monospacedDigit() }
    }
    private func detail(_ title: String, _ amount: Int64) -> some View {
        HStack { Text(title).foregroundStyle(secondary); Spacer(); Text(compactNumber(amount)).monospacedDigit() }
    }
}

/// One drawing surface instead of hundreds of native controls. The date picker
/// above the detail rows provides keyboard/VoiceOver access to every day.
private struct HistoryHeatmap: View {
    let map: UsageHeatmap
    let calendar: Calendar
    @Binding var selected: Date
    @Environment(\.colorScheme) private var scheme
    @State private var hovered: Date?
    private let size: CGFloat = 10, gap: CGFloat = 3, left: CGFloat = 24, top: CGFloat = 18
    var body: some View {
        let palette = Self.colors(dark: scheme == .dark)
        let secondary = PanelStyle.secondary(scheme)
        Canvas { context, _ in
            for (row, label) in [(0, "一"), (2, "三"), (4, "五"), (6, "日")] {
                context.draw(Text(label).font(.system(size: 9)).foregroundColor(secondary), at: CGPoint(x: 0, y: top + CGFloat(row) * (size + gap) + size / 2), anchor: .leading)
            }
            for cell in map.cells {
                let rect = CGRect(x: left + CGFloat(cell.week) * (size + gap), y: top + CGFloat(cell.weekday) * (size + gap), width: size, height: size)
                let path = Path(roundedRect: rect, cornerRadius: 2)
                if cell.future { context.stroke(path, with: .color(secondary.opacity(0.18)), style: StrokeStyle(lineWidth: 0.5, dash: [1, 2])) }
                else { context.fill(path, with: .color(palette[cell.level])) }
                if calendar.component(.day, from: cell.date) == 1 {
                    let label = "\(calendar.component(.month, from: cell.date))月"
                    context.draw(Text(label).font(.system(size: 9)).foregroundColor(secondary), at: CGPoint(x: rect.minX, y: 0), anchor: .topLeading)
                }
                if calendar.isDate(cell.date, inSameDayAs: selected), !cell.future {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: -1.2, dy: -1.2), cornerRadius: 2.5), with: .color(.primary), lineWidth: 1.3)
                } else if hovered == cell.date {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: -0.7, dy: -0.7), cornerRadius: 2), with: .color(secondary), lineWidth: 1)
                }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            let next: Date?
            switch phase { case .active(let point): next = hit(point)?.date; case .ended: next = nil }
            if hovered != next { hovered = next }
        }
        .onTapGesture(coordinateSpace: .local) { point in if let day = hit(point), !day.future { selected = day.date } }
        .help(tooltip)
        .accessibilityElement(children: .ignore).accessibilityLabel("每日 token 热力图")
        .accessibilityValue("可使用下方日期选择器查看每天的准确数值")
    }
    private var tooltip: String {
        guard let hovered, let cell = map.cells.first(where: { $0.date == hovered }) else { return "每格一天，颜色越深用量越多。点击查看当天明细。" }
        let date = cell.date.formatted(date: .complete, time: .omitted)
        return cell.future ? "\(date) · 未来日期" : cell.usage.records == 0 ? "\(date) · 无已索引本机记录" : "\(date) · 已记录 \(cell.usage.tokens.total.formatted()) tokens"
    }
    private func hit(_ point: CGPoint) -> HeatmapCell? {
        guard point.x >= left, point.y >= top else { return nil }
        let column = Int((point.x - left) / (size + gap)), row = Int((point.y - top) / (size + gap))
        guard row < 7, column < map.weeks,
              (point.x - left).truncatingRemainder(dividingBy: size + gap) < size,
              (point.y - top).truncatingRemainder(dividingBy: size + gap) < size else { return nil }
        let index = column * 7 + row - (map.cells.first?.weekday ?? 0)
        return map.cells.indices.contains(index) ? map.cells[index] : nil
    }
    static func colors(dark: Bool) -> [Color] {
        let hex: [UInt32] = dark ? [0x292f36, 0x0e4429, 0x006d32, 0x26a641, 0x39d353] : [0xebedf0, 0x9be9a8, 0x40c463, 0x30a14e, 0x216e39]
        return hex.map { Color(red: Double(($0 >> 16) & 255) / 255, green: Double(($0 >> 8) & 255) / 255, blue: Double($0 & 255) / 255) }
    }
}
