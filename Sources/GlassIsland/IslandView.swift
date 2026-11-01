import SwiftUI

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
            scrollArea
            footer
        }
        .frame(width: 344)
        .onHover { model.setHovering($0) }
        .onExitCommand { model.dismiss() }
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
            IconButton(systemName: "arrow.up.forward.app", help: "在 Obsidian 中打开收件箱") {
                store.openNote()
            }
            .disabled(store.pending)
            // SwiftUI Menu cannot open inside a non-activating panel; the
            // AppKit layer pops up a native NSMenu instead (see AppDelegate).
            IconButton(systemName: "ellipsis", help: "窗口选项（右键胶囊/标题同此菜单）") {
                model.onMenuAction(.showPanelMenu)
            }
        }
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 14, trailing: 18))
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
                                isPending: store.pendingLine == task.line,
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
                        Button("撤销") { store.undo() }
                            .font(.system(size: 12))
                            .foregroundColor(Palette.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.undoBackground))
                            .buttonStyle(.plain)
                            .disabled(store.pending)
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
                IconButton(systemName: "arrow.clockwise", help: "刷新任务") {
                    store.refresh()
                }
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
            Button(action: toggle) {
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
            }
            .buttonStyle(.plain)
            .disabled(isPending)
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

private struct IconButton: View {
    let systemName: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
                .foregroundColor(hovering ? Palette.blue : (tint ?? Palette.muted))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Palette.control : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
