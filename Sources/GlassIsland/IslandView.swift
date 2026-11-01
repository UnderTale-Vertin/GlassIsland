import SwiftUI

/// Reports a view's frame in SCREEN coordinates (.global, top-left origin).
/// The controller converts to window space; named coordinate spaces proved
/// unreliable here (resolved to local frames, misplacing every control).
private struct ReportFrame: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                Color.clear
                    .onAppear { IslandControlBridge.shared.model?.reportFrame(id, frame) }
                    .onChange(of: frame) { _, newFrame in
                        IslandControlBridge.shared.model?.reportFrame(id, newFrame)
                    }
            }
        )
    }
}

private extension View {
    func reportFrame(_ id: String) -> some View {
        modifier(ReportFrame(id: id))
    }
}

// Palette mirrors the original resources/ui/style.css dark glass theme.
enum Palette {
    static let ink = Color(red: 0.949, green: 0.965, blue: 0.980)
    static let muted = Color(red: 0.839, green: 0.878, blue: 0.914)
    static let blue = Color(red: 0.757, green: 0.898, blue: 1.0)
    static let hoverRow = Color.white.opacity(0.06)
    static let control = Color.white.opacity(0.09)
    static let separator = Color(red: 0.867, green: 0.929, blue: 0.980).opacity(0.10)
    static let checkBorder = Color(red: 0.714, green: 0.788, blue: 0.851)
    static let checkHover = Color(red: 0.612, green: 0.824, blue: 1.0)
    static let checkedFill = Color(red: 0.071, green: 0.416, blue: 0.663)
    static let errorText = Color(red: 1.0, green: 0.827, blue: 0.780)
    static let undoBackground = Color(red: 0.314, green: 0.541, blue: 0.710).opacity(0.10)

    static func hex(_ value: UInt) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

// MARK: - Root

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: TaskStore

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassRoot(model: model, store: store)
            } else {
                LegacyRoot(model: model, store: store)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            store.openLink(urlString: url.absoluteString)
            return .handled
        })
    }
}

// MARK: - macOS 26 Liquid Glass root (capsule ↔ panel morph)

@available(macOS 26.0, *)
private struct GlassRoot: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: TaskStore
    @Namespace private var glassNS

    var body: some View {
        GlassEffectContainer(spacing: 20) {
            ZStack(alignment: .top) {
                if model.expanded {
                    PanelContent(model: model, store: store)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
                        .glassEffectID("island", in: glassNS)
                } else {
                    CapsuleContent(model: model, store: store)
                        .glassEffect(.regular.tint(.black.opacity(0.92)).interactive(), in: .capsule)
                        .glassEffectID("island", in: glassNS)
                }
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.expanded)
    }
}

// MARK: - Pre-macOS-26 fallback

private struct LegacyRoot: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: TaskStore

    var body: some View {
        ZStack(alignment: .top) {
            if model.expanded {
                PanelContent(model: model, store: store)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
                    .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            } else {
                CapsuleContent(model: model, store: store)
                    .background(Color.black.opacity(0.85), in: Capsule())
                    .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.expanded)
    }
}

// MARK: - Collapsed pill

struct CapsuleContent: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: TaskStore

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: store.configured ? "checkmark.circle" : "questionmark.circle")
                .font(.system(size: 13, weight: .semibold))
            Text(store.configured ? "\(store.tasks.count)" : "…")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundColor(.white.opacity(0.92))
        .padding(.horizontal, 15)
        .frame(height: 34)
        .contentShape(Capsule())
        .onHover { model.setHovering($0) }
        .accessibilityLabel("Obsidian 待办：\(store.tasks.count) 项未完成")
    }
}

// MARK: - Expanded glass panel

struct PanelContent: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: TaskStore

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.showOptions {
                optionsSection
            }
            scrollArea
            footer
        }
        .frame(width: 344)
        .onHover { model.setHovering($0) }
        .onExitCommand {
            if model.showOptions {
                model.showOptions = false
            } else {
                model.dismiss()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Clicks here are handled by the AppKit ToggleZoneView layered
            // above this area (see IslandController) — pin on first click,
            // hide on the next.
            HStack(spacing: 8) {
                Text("Inbox")
                    .font(.custom("Parisienne", size: 29))
                    .foregroundColor(Palette.ink)
                Text("\(store.tasks.count)")
                    .font(.system(size: 14))
                    .monospacedDigit()
                    .foregroundColor(Palette.muted)
                    .accessibilityLabel("未完成任务数")
            }
            Spacer(minLength: 8)
            IconButton(systemName: "arrow.up.forward.app", help: "在 Obsidian 中打开收件箱")
                .reportFrame("ctrl:open")
                .opacity(store.pending ? 0.55 : 1)
            // Pure-SwiftUI inline options: popup menus (SwiftUI Menu or
            // NSMenu.popUp) cannot open from a non-activating panel.
            IconButton(systemName: "ellipsis", help: "选项", tint: model.showOptions ? Palette.blue : nil)
                .reportFrame("ctrl:options")
        }
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 14, trailing: 18))
    }

    @ViewBuilder
    private var optionsSection: some View {
        VStack(spacing: 1) {
            OptionRow(icon: "arrow.clockwise", label: "立即刷新") {
                store.refresh()
                model.showOptions = false
            }
            OptionRow(icon: "arrow.up.forward.app", label: "在 Obsidian 中打开") {
                model.showOptions = false
                model.onMenuAction(.openNote)
            }
            if model.pickingFromObsidian {
                OptionRow(icon: "checkmark.circle.fill", label: "完成：采用 Obsidian 当前笔记", highlight: true) {
                    model.showOptions = false
                    model.onMenuAction(.finishObsidianPick)
                }
            } else {
                OptionRow(icon: "books.vertical", label: "从 Obsidian 选择当前笔记") {
                    model.onMenuAction(.startObsidianPick)
                }
            }
            OptionRow(icon: "folder", label: "选择文件夹（监控其中全部笔记）…") {
                model.showOptions = false
                model.onMenuAction(.pickFolder)
            }
            OptionRow(
                icon: model.mode == .island ? "rectangle.on.rectangle" : "dot.square",
                label: model.mode == .island ? "切换到桌面浮窗模式" : "切换到灵动岛模式"
            ) {
                model.showOptions = false
                model.onMenuAction(.switchMode)
            }
            if model.mode == .floating {
                OptionRow(
                    icon: "pin",
                    label: model.onTop ? "取消窗口置顶" : "窗口置顶"
                ) {
                    model.showOptions = false
                    model.onMenuAction(.toggleOnTop)
                }
            }
            Divider().overlay(Palette.separator).padding(.vertical, 3)
            OptionRow(icon: "doc.text", label: "选择任务笔记…") {
                model.showOptions = false
                model.onMenuAction(.pickNote)
            }
            OptionRow(icon: "power", label: "退出 GlassIsland", isDestructive: true) {
                model.onMenuAction(.quit)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var scrollArea: some View {
        if store.sourceText == nil && !store.configured {
            VStack(spacing: 4) {
                Text("还没有选择任务笔记")
                    .font(.system(size: 15))
                    .foregroundColor(Palette.ink)
                Text("点击菜单栏图标选择一篇 Markdown 笔记")
                    .font(.system(size: 13))
                    .foregroundColor(Palette.muted)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 40)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.sourceText == nil {
                        Text("正在读取收件箱…")
                            .font(.system(size: 13))
                            .foregroundColor(Palette.muted)
                            .padding(.horizontal, 10)
                            .padding(.top, 18)
                            .padding(.bottom, 30)
                    } else if store.tasks.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(store.tasks.enumerated()), id: \.element.id) { index, task in
                            TaskRow(
                                task: task,
                                showsSeparator: index > 0,
                                isPending: store.pendingItemID == task.id,
                                toggle: { store.toggle(task) },
                                hoveredLine: $model.hoveredLine
                            )
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(maxHeight: 460)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundColor(Palette.blue)
            Text("都处理好了")
                .font(.system(size: 17))
                .foregroundColor(Palette.ink)
                .padding(.top, 12)
            Text("新任务会自动出现在这里")
                .font(.system(size: 13))
                .foregroundColor(Palette.muted)
                .padding(.top, 7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if store.notice != nil || store.undoTask != nil {
                HStack(spacing: 12) {
                    if let notice = store.notice {
                        Text(notice.text)
                            .font(.system(size: 12))
                            .foregroundColor(notice.isError ? Palette.errorText : Palette.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if store.undoTask != nil {
                        Text("撤销")
                            .font(.system(size: 12))
                            .foregroundColor(Palette.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.undoBackground))
                            .opacity(store.pending ? 0.55 : 1)
                            .reportFrame("ctrl:undo")
                    }
                }
                .padding(.top, 6)
            }
            HStack(spacing: 8) {
                Text(store.statusText)
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .italic()
                    .foregroundColor(Palette.muted)
                Spacer(minLength: 8)
                IconButton(systemName: "arrow.clockwise", help: "刷新任务")
                    .reportFrame("ctrl:refresh")
                    .opacity(store.pending ? 0.55 : 1)
            }
            .padding(.top, 4)
        }
        .padding(EdgeInsets(top: 8, leading: 22, bottom: 14, trailing: 16))
    }
}

// MARK: - Rows and controls

private struct TaskRow: View {
    let task: TaskItem
    let showsSeparator: Bool
    let isPending: Bool
    let toggle: () -> Void
    @Binding var hoveredLine: String?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Visual only; the AppKit overlay ("circle:<id>") fires the toggle.
            ZStack {
                Circle()
                    .fill(Color.white.opacity(hovering ? 0.13 : 0.08))
                Circle()
                    .strokeBorder(hovering ? Palette.checkHover : Palette.checkBorder, lineWidth: 1.4)
            }
            .frame(width: 16, height: 16)
            .frame(width: 28)
            .contentShape(Rectangle())
            .padding(.vertical, 4.5)
            .reportFrame("circle:\(task.id)")
            .accessibilityLabel("完成：\(task.body)")

            Text(InlineHTML.attributed(task.html, ink: Palette.ink, muted: Palette.muted, blue: Palette.blue, baseSize: 15))
                .textShadow()
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hovering && !isPending ? Palette.hoverRow : Color.clear)
        )
        .opacity(isPending ? 0.55 : 1)
        .overlay(alignment: .top) {
            if showsSeparator {
                Rectangle()
                    .fill(Palette.separator)
                    .frame(height: 1)
                    .padding(.leading, 26)
                    .padding(.trailing, 10)
            }
        }
        .onHover { h in
            hovering = h
            hoveredLine = h ? task.line : nil
        }
    }
}

private struct OptionRow: View {
    let icon: String
    let label: String
    var isDestructive = false
    var highlight = false
    let action: () -> Void
    @State private var hovering = false

    private var controlID: String { "option:\(label)" }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 13, height: 13)
                .foregroundColor(hovering || highlight ? Palette.blue : Palette.muted)
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(isDestructive ? Palette.errorText : (hovering || highlight ? Palette.ink : Palette.muted))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Palette.control : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear { IslandControlBridge.shared.setAction(controlID, action) }
        .reportFrame(controlID)
    }
}

private struct IconButton: View {
    let systemName: String
    let help: String
    var tint: Color? = nil
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: 15, height: 15)
            .foregroundColor(hovering ? Palette.blue : (tint ?? Palette.muted))
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Palette.control : Color.clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help(help)
    }
}

private extension Text {
    /// The original CSS uses a soft dark text shadow for legibility on glass.
    func textShadow() -> some View {
        shadow(color: .black.opacity(0.85), radius: 1, x: 0, y: 1)
    }
}
