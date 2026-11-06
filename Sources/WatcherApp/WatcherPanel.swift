import SwiftUI
import AppKit
import WatcherCore

struct WatcherPanel: View {
    @ObservedObject var model: WatcherModel
    @Environment(\.colorScheme) private var scheme
    private var secondary: Color { PanelStyle.secondary(scheme) }
    private var amber: Color { PanelStyle.warning(scheme) }
    var body: some View {
        VStack(spacing: 0) {
            if model.page != .home {
                HStack(spacing: 6) {
                    iconButton("chevron.left", "返回总览 · Esc") { model.navigate(.home) }
                    Text(pageTitle).font(.system(size: 12, weight: .medium)).foregroundStyle(secondary)
                    Spacer()
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
            switch model.page {
            case .home: home
            case .quota: quotaDetails
            case .usage: usageDetails
            case .history: UsageHistoryView(model: model)
            case .legend: statusLegend
            case .session(let key): sessionDetails(key)
            }
            Spacer(minLength: 0)
            footer
        }.font(.system(size: 12)).frame(width: model.panelWidth, height: model.panelHeight, alignment: .top)
            .background(.background).transaction { $0.animation = nil }
            .onExitCommand { if model.page != .home { model.navigate(.home) } else { NSApp.keyWindow?.close() } }
    }
    private var home: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text("会话 \(model.filteredSessions.count)").foregroundStyle(secondary).font(.system(size: 10)).monospacedDigit()
                iconButton("info.circle", "查看状态符号与时间说明") { model.navigate(.legend) }
                if model.filteredSessions.count > 5 {
                    Button { model.showAllSessions.toggle(); model.resize?(model.panelHeight) } label: {
                        Image(systemName: model.showAllSessions ? "chevron.up" : "chevron.down").font(.system(size: 9)).frame(width: 18, height: 28).contentShape(Rectangle())
                    }.buttonStyle(QuietButtonStyle()).foregroundStyle(secondary)
                        .help(model.showAllSessions ? "收起会话" : "展开全部会话")
                        .accessibilityLabel(model.showAllSessions ? "收起会话" : "展开全部会话")
                }
                Spacer(minLength: 3)
                Picker("筛选 Agent", selection: Binding(get: { model.selectedProvider }, set: { model.selectedProvider = $0; model.resize?(model.panelHeight) })) {
                    Text("全部").tag(AgentProvider?.none)
                    Text("Codex").tag(AgentProvider?.some(.codex))
                    Text("Claude").tag(AgentProvider?.some(.claude))
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 150)
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
            if model.visibleSessions.isEmpty {
                HStack { Image(systemName: "circle.dotted"); Text(model.isIndexing ? "正在读取本机记录" : "暂无近期会话") }.foregroundStyle(secondary).font(.system(size: 11)).frame(height: 36)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleSessions, id: \.key) { session in
                            Button { model.navigate(.session(session.key)) } label: {
                                HStack(spacing: 9) {
                                    AgentIcon(provider: session.provider, size: 20).accessibilityHidden(true)
                                    Text(session.project).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 3)
                                    SessionStatusIcon(status: model.projectedStatus(session)).help(model.statusHelp(session))
                                    Text(shortAge(session.observedAt)).monospacedDigit().font(.system(size: 10)).foregroundStyle(secondary).frame(width: 29, alignment: .trailing)
                                        .help("距最近状态记录 \(shortAge(session.observedAt))，不是工作时长")
                                }.padding(.horizontal, 6).frame(height: 36).contentShape(Rectangle())
                            }.buttonStyle(QuietButtonStyle()).help("\(session.provider.name) · \(session.project)\n\(model.statusHelp(session))\n最近记录 \(shortAge(session.observedAt)) 前；点击查看详情")
                                .accessibilityLabel("\(session.provider.name)，\(session.project)，\(model.projectedStatus(session).label)，最近记录 \(shortAge(session.observedAt)) 前")
                        }
                    }.padding(.horizontal, 9)
                }.frame(height: CGFloat(min(model.visibleSessions.count, model.showAllSessions ? 9 : 5) * 36))
            }
            if model.isIndexing {
                HStack { Text("索引"); Spacer(); Text("\(model.index.usage.filesDone + model.claudeIndex.usage.filesDone)/\(model.index.usage.filesTotal + model.claudeIndex.usage.filesTotal)") }.font(.system(size: 10)).foregroundStyle(secondary).padding(.horizontal, 16).frame(height: 24)
            }
            Spacer(minLength: 8)
        }
    }
    /// Account rings on the left; local token total, refresh and quit on the right.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 12)
            HStack(spacing: 6) {
                quotaButton(.codex, remaining: model.quota?.windows.first(where: { $0.name == "Codex" && $0.seconds == 604800 })?.remainingPercent)
                quotaButton(.claude, remaining: model.claudeQuota?.windows.first(where: { $0.id == "seven_day" })?.remainingPercent)
                Spacer(minLength: 6)
                Button { model.navigate(.history) } label: {
                    HStack(spacing: 3) {
                        Text(model.todayTokenText).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        if model.index.usage.isPartial || model.claudeIndex.usage.isPartial {
                            Image(systemName: "exclamationmark.circle").font(.system(size: 9)).foregroundStyle(secondary)
                        }
                    }.frame(height: 28).padding(.horizontal, 3).contentShape(Rectangle())
                }.buttonStyle(QuietButtonStyle())
                    .help("今日两种 Agent 的本机 token 合计，每小时更新；点击查看历史。标记表示部分统计。")
                    .accessibilityLabel("今日总 token，\(model.todayTokenText)，打开历史用量")
                iconButton(model.quotaBusy ? "ellipsis" : "arrow.clockwise", "刷新统计与额度 · ⌘R") { model.requestScan(); model.refreshQuota(manual: true) }.disabled(model.quotaBusy).keyboardShortcut("r")
                iconButton("power", "退出 a-watcher · ⌘Q") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }.padding(.horizontal, 10).frame(height: 40)
        }
    }
    private func quotaButton(_ provider: AgentProvider, remaining: Int?) -> some View {
        Button { model.showQuota(provider) } label: {
            HStack(spacing: 5) {
                AgentIcon(provider: provider, size: 18)
                QuotaRing(remaining: remaining, stale: model.accountQuotaError(provider) != nil)
            }.frame(height: 28).padding(.horizontal, 3).contentShape(Rectangle())
        }.buttonStyle(QuietButtonStyle())
            .help(provider.name + " · 7 日剩余 " + (remaining.map { "\($0)%" } ?? "暂不可用") + (model.accountQuotaError(provider) != nil ? " · 数据未刷新" : "") + "；点击查看详情")
            .accessibilityLabel(provider.name + "，7 日剩余 " + (remaining.map { "\($0)%" } ?? "未知") + "，查看详情")
    }
    private var quotaDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                heading(model.quotaProvider, "账户剩余额度")
                if let quota = model.accountQuota(model.quotaProvider) {
                    ForEach(quota.windows) { window in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack { Text(window.name == "Codex" ? window.shortLabel : "\(window.name) · \(window.shortLabel)"); Spacer(); Text("\(window.remainingPercent)%").font(.system(size: 21, weight: .medium)).monospacedDigit() }
                            if let date = window.resetsAt { Text("重置 \(date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(secondary) }
                        }
                    }
                    if quota.unlimitedCredits { row("积分", "无限") } else if let balance = quota.creditBalance { row("积分余额", balance) }
                    if model.quotaProvider == .claude {
                        if !quota.windows.contains(where: { $0.id == "seven_day" }) { row("7 日剩余", "未知") }
                        if let billing = quota.claudeBilling {
                            row("额外用量计费", billing.enabled.map { $0 ? "已启用" : "未启用" } ?? "未知")
                            if billing.enabled != false {
                                row("账期支出", billing.spent?.formatted ?? "未知")
                                row("支出上限", billing.limit?.formatted ?? "未知")
                                row("剩余支出预算", billing.remainingBudget?.formatted ?? "未知")
                            }
                            row("账户余额", billing.balance?.formatted ?? "未知")
                        } else { row("额外用量计费", "未知"); row("账户余额", "未知") }
                        Text("支出预算与账户余额分开显示；缺失字段不作估算。").font(.system(size: 10)).foregroundStyle(secondary)
                    }
                    row("采集", quota.capturedAt.formatted(date: .omitted, time: .shortened)); row("范围", "账户 · 含其他设备")
                }
                if let error = model.accountQuotaError(model.quotaProvider) { Text(error.message(for: model.quotaProvider)).font(.system(size: 11)).foregroundStyle(amber) }
                Button("查看 \(model.quotaProvider.name) 本机用量") { model.showUsage(model.quotaProvider) }.buttonStyle(.bordered).controlSize(.small)
            }.padding(16)
        }
    }
    private var usageDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                heading(model.usageProvider, "本机用量")
                Picker("Agent", selection: Binding(get: { model.usageProvider }, set: { model.showUsage($0) })) { Text("Codex").tag(AgentProvider.codex); Text("Claude").tag(AgentProvider.claude) }.pickerStyle(.segmented).labelsHidden()
                Picker("日期范围", selection: Binding(get: { model.days }, set: { model.selectDays($0) })) { Text("今日").tag(1); Text("7 日").tag(7); Text("30 日").tag(30) }.pickerStyle(.segmented).labelsHidden()
                if model.detailUsage.isPartial { Text("部分统计 · 已确认小计").font(.system(size: 10)).foregroundStyle(amber) }
                Text(compactNumber(model.detailUsage.tokens.total)).font(.system(size: 30, weight: .medium)).monospacedDigit()
                Text("tokens · 这台 Mac · 每小时更新").font(.system(size: 10)).foregroundStyle(secondary)
                row("输入合计", compactNumber(model.detailUsage.tokens.input)); row("缓存读取¹", compactNumber(model.detailUsage.tokens.cached))
                row("缓存写入¹", compactNumber(model.detailUsage.tokens.cacheWrite)); row("输出合计", compactNumber(model.detailUsage.tokens.output))
                if model.usageProvider == .codex { row("推理¹", compactNumber(model.detailUsage.tokens.reasoning)) }
                ForEach(model.detailUsage.byModel.prefix(8)) { row($0.name, compactNumber($0.tokens)) }
                Text("¹ 已含在输入或输出中，不重复相加。").font(.system(size: 10)).foregroundStyle(secondary)
                if model.detailUsage.isPartial { Text("跳过 \(model.detailUsage.skippedLines) 行 · 未完成请求 \(model.detailUsage.incompleteRequests) · 待确认继承 \(model.detailUsage.unresolvedForks) · 压缩文件 \(model.detailUsage.compressedFiles)").font(.system(size: 10)).foregroundStyle(secondary) }
            }.padding(16)
        }
    }
    private var statusLegend: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("符号表示最近确认的状态").font(.system(size: 15, weight: .semibold))
                VStack(spacing: 12) {
                    legendRow(.running, "正在工作", "包括模型执行与工具调用，工作时播放动效")
                    legendRow(.idle, "本轮完成", "已收到完成记录，会话可继续")
                    legendRow(.unknown, "状态待确认", "证据不足，不能判断是否还在工作")
                }
                Divider()
                Text("3 分钟没有新记录 ≠ 已停工").font(.system(size: 12, weight: .medium))
                Text("上次还在工作，但超过 3 分钟没有新的状态记录，就显示待确认。可能仍在等待或执行，也可能已经退出；仅靠日志无法区分。已明确完成的会话仍显示勾。").font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "clock").frame(width: 16)
                    Text("右侧时间是距最近状态记录的时间，不是工作时长。").fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 11)).foregroundStyle(secondary)
                DisclosureGroup("其他状态") {
                    VStack(spacing: 12) {
                        legendRow(.waitingApproval, "等待批准", "仅在明确识别到批准等待时显示")
                        legendRow(.waitingInput, "等待输入", "需要你的回答")
                        legendRow(.interrupted, "已中断", "本轮被停止")
                        legendRow(.error, "发生错误", "最近记录了错误，进入 Agent 查看")
                        legendRow(.ended, "会话已结束", "已收到会话结束记录")
                    }.padding(.top, 10)
                }.font(.system(size: 11))
            }.padding(16)
        }
    }
    private func legendRow(_ status: SessionStatus, _ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SessionStatusIcon(status: status, animate: false).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(description).font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
    @ViewBuilder private func sessionDetails(_ key: String) -> some View {
        if let session = model.allSessions.first(where: { $0.key == key }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        AgentIcon(provider: session.provider, size: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.project).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                            Text(session.provider.name).font(.system(size: 11)).foregroundStyle(secondary)
                        }
                    }
                    HStack(spacing: 7) { SessionStatusIcon(status: model.projectedStatus(session)); Text(model.projectedStatus(session).label).font(.system(size: 12, weight: .medium)) }
                    if model.projectedStatus(session) == .unknown, [.running, .tool].contains(session.status) {
                        Text(model.statusHelp(session)).font(.system(size: 10)).foregroundStyle(secondary)
                    }
                    Divider()
                    row("模型", session.model)
                    if let project = session.projectDirectory { row("所属项目", project) }
                    if !session.directory.isEmpty { row("最近记录目录", session.directory) }
                    row("最近记录", session.observedAt.formatted(date: .abbreviated, time: .shortened)); row("来源", session.source)
                    row("会话编号", String(session.id.suffix(8)))
                    Button(session.provider == .codex ? "打开 Codex" : "打开项目文件夹") { model.openSession(session) }.buttonStyle(.bordered).controlSize(.small)
                }.padding(16)
            }
        } else { Text("会话已不在近期列表").foregroundStyle(secondary).padding(16) }
    }
    private func heading(_ provider: AgentProvider, _ subtitle: String) -> some View {
        HStack(spacing: 9) { AgentIcon(provider: provider, size: 30); VStack(alignment: .leading, spacing: 3) { Text(provider.name).font(.system(size: 14, weight: .semibold)); Text(subtitle).font(.system(size: 11)).foregroundStyle(secondary) } }
    }
    private func row(_ title: String, _ value: String) -> some View { HStack(alignment: .firstTextBaseline) { Text(title).foregroundStyle(secondary).fixedSize(); Spacer(minLength: 8); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.system(size: 11)) }
    private func iconButton(_ name: String, _ label: String, _ action: @escaping () -> Void) -> some View { Button(action: action) { Image(systemName: name).frame(width: 28, height: 28).contentShape(Rectangle()) }.buttonStyle(QuietButtonStyle()).foregroundStyle(secondary).help(label).accessibilityLabel(label) }
    private var pageTitle: String {
        switch model.page {
        case .home: "a-watcher"
        case .quota: "账户额度"
        case .usage: "本机用量"
        case .history: ""
        case .legend: "状态说明"
        case .session: "会话"
        }
    }
}
