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
            case .detail: details
            case .history: UsageHistoryView(model: model)
            case .help: help
            case .session(let key): sessionDetails(key)
            }
            Spacer(minLength: 0)
            footer
        }.font(.system(size: 12)).frame(width: model.panelWidth, height: model.panelHeight, alignment: .top)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
            .transaction { $0.animation = nil }
            .onExitCommand { if model.page != .home { model.navigate(.home) } else { NSApp.keyWindow?.close() } }
    }
    private var home: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text("会话 \(model.filteredSessions.count)").foregroundStyle(secondary).font(.system(size: 10)).monospacedDigit()
                iconButton("info.circle", "帮助：菜单栏图标与状态符号") { model.navigate(.help) }
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
        Button { model.showDetail(provider) } label: {
            HStack(spacing: 5) {
                AgentIcon(provider: provider, size: 18)
                QuotaRing(remaining: remaining, stale: model.accountQuotaError(provider) != nil)
            }.frame(height: 28).padding(.horizontal, 3).contentShape(Rectangle())
        }.buttonStyle(QuietButtonStyle())
            .help(provider.name + " · 7 日剩余 " + (remaining.map { "\($0)%" } ?? "暂不可用") + (model.accountQuotaError(provider) != nil ? " · 数据未刷新" : "") + "；点击查看详情")
            .accessibilityLabel(provider.name + "，7 日剩余 " + (remaining.map { "\($0)%" } ?? "未知") + "，查看详情")
    }
    /// One page per Agent: account quota (all devices) above local usage (this Mac).
    private var details: some View {
        let provider = model.detailProvider
        return ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    AgentIcon(provider: provider, size: 26)
                    Text(provider.name).font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 6)
                    Picker("Agent", selection: Binding(get: { model.detailProvider }, set: { model.showDetail($0) })) { Text("Codex").tag(AgentProvider.codex); Text("Claude").tag(AgentProvider.claude) }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 120)
                }
                sectionTitle("账户额度", "账户 · 含其他设备")
                if let quota = model.accountQuota(provider) {
                    ForEach(quota.windows) { window in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(window.name == "Codex" ? window.shortLabel : "\(window.name) · \(window.shortLabel)")
                                if let date = window.resetsAt { Text("重置 \(date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(secondary) }
                            }
                            Spacer()
                            Text("\(window.remainingPercent)%").font(.system(size: 18, weight: .medium)).monospacedDigit()
                        }
                    }
                    if quota.unlimitedCredits { row("积分", "无限") } else if let balance = quota.creditBalance { row("积分余额", balance) }
                    if provider == .claude {
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
                    }
                    row("采集", quota.capturedAt.formatted(date: .omitted, time: .shortened))
                } else if model.accountQuotaError(provider) == nil {
                    Text("暂无额度数据").font(.system(size: 11)).foregroundStyle(secondary)
                }
                if let error = model.accountQuotaError(provider) { Text(error.message(for: provider)).font(.system(size: 11)).foregroundStyle(amber).fixedSize(horizontal: false, vertical: true) }
                Divider().padding(.vertical, 2)
                sectionTitle("本机用量", "这台 Mac · 每小时更新")
                Picker("日期范围", selection: Binding(get: { model.days }, set: { model.selectDays($0) })) { Text("今日").tag(1); Text("7 日").tag(7); Text("30 日").tag(30) }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(compactNumber(model.detailUsage.tokens.total)).font(.system(size: 24, weight: .medium)).monospacedDigit()
                    Text("tokens").font(.system(size: 10)).foregroundStyle(secondary)
                    Spacer()
                    if model.detailUsage.isPartial { Text("部分统计").font(.system(size: 10)).foregroundStyle(amber) }
                }
                row("输入合计", compactNumber(model.detailUsage.tokens.input)); row("缓存读取¹", compactNumber(model.detailUsage.tokens.cached))
                row("缓存写入¹", compactNumber(model.detailUsage.tokens.cacheWrite)); row("输出合计", compactNumber(model.detailUsage.tokens.output))
                if provider == .codex { row("推理¹", compactNumber(model.detailUsage.tokens.reasoning)) }
                ForEach(model.detailUsage.byModel.prefix(8)) { row($0.name, compactNumber($0.tokens)) }
                Text("¹ 已含在输入或输出中，不重复相加。").font(.system(size: 10)).foregroundStyle(secondary)
                if model.detailUsage.isPartial { Text("跳过 \(model.detailUsage.skippedLines) 行 · 未完成请求 \(model.detailUsage.incompleteRequests) · 待确认继承 \(model.detailUsage.unresolvedForks) · 压缩文件 \(model.detailUsage.compressedFiles)").font(.system(size: 10)).foregroundStyle(secondary) }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 14)
        }
    }
    private func sectionTitle(_ title: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(note).font(.system(size: 10)).foregroundStyle(secondary)
        }.padding(.top, 2)
    }
    /// Help: menu bar icon states, session symbols, and two one-line notes.
    private var help: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("菜单栏图标", "打开面板后清除未读")
                VStack(spacing: 7) {
                    iconRow(ActivityUpdate(mode: .idle), "空闲", "静止波形，没有确认在工作的会话")
                    iconRow(ActivityUpdate(mode: .working, active: 2), "工作中", "数字为工作中的会话数，波形持续跳动")
                    iconRow(ActivityUpdate(mode: .attention, active: 2, attention: 1), "工作中，另有待处理", "橙点：有会话等待回复或出错")
                    iconRow(ActivityUpdate(mode: .attention, attention: 1), "需要处理", "等待输入、批准或发生错误")
                    iconRow(ActivityUpdate(mode: .completed, unread: 1), "完成未读", "有会话完成本轮工作")
                }
                Divider().padding(.vertical, 2)
                sectionTitle("会话状态", "")
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach([SessionStatus.running, .idle, .waitingInput, .waitingApproval, .error, .interrupted, .ended, .unknown], id: \.self) { status in
                        HStack(spacing: 6) {
                            SessionStatusIcon(status: status, animate: false).accessibilityHidden(true)
                            Text(status == .running ? "工作中" : status.label).font(.system(size: 11))
                        }
                    }
                }
                Divider().padding(.vertical, 2)
                noteRow("clock", "右侧时间是距最近记录，不是工作时长")
                noteRow("circle.dashed", "3 分钟无新记录显示待确认，不代表已完成")
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 14)
        }
    }
    private func iconRow(_ state: ActivityUpdate, _ title: String, _ description: String) -> some View {
        HStack(spacing: 10) {
            MenuIconSample(state: state).frame(width: 46, alignment: .leading).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(description).font(.system(size: 10)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.accessibilityElement(children: .combine)
    }
    private func noteRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) { Image(systemName: symbol).frame(width: 16); Text(text).fixedSize(horizontal: false, vertical: true) }
            .font(.system(size: 11)).foregroundStyle(secondary)
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
        case .detail: "详情"
        case .history: ""
        case .help: "帮助"
        case .session: "会话"
        }
    }
}
