# GlassIsland

> [!IMPORTANT]
> 本项目是 [Wang060919/ObsidianGlassTasks](https://github.com/Wang060919/ObsidianGlassTasks) 的 **macOS 移植版**。任务提取脚本（`Resources/vendor/tasks.js`，改自 `resources/ui/tasks.mjs`）、界面设计与中文文案均来自该项目，特此引用与致谢；第三方组件许可见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

把 ObsidianGlassTasks 的「液态玻璃 Obsidian 待办」移植到 macOS，并以**灵动岛**形态呈现：屏幕顶部（刘海位）的黑色玻璃胶囊，悬停即展开任务面板，点击固定、再点消失。

- macOS 14+（macOS 26 使用系统原生 Liquid Glass 与胶囊↔面板形变动画；旧系统回退 `.ultraThinMaterial`）
- 纯原生 Swift（AppKit 壳 + SwiftUI 内容层 + JavaScriptCore），无第三方依赖
- 任务提取逻辑直接复用原仓库的 markdown-it 脚本，与 Windows 版**逐字节同语义**

## 它能做什么

与原版一致：读取一篇 Markdown 笔记，把未完成的 `- [ ]` 任务显示在玻璃面板上；勾选后只翻转原文件中那一个字节写回（保留 BOM、换行与一切其他内容）；支持撤销最近一次完成、`[[双链]]` 跳转 Obsidian、行内 Markdown（粗体/斜体/代码/删除线/链接）、隐藏 `#todo` 标签、约 2 秒自动同步。

相比 Windows 版的差异：

| 原版（Windows） | GlassIsland（macOS） |
| --- | --- |
| D3D11 + Desktop Duplication 采集桌面做折射 | 系统 Liquid Glass 材质（无屏幕采集，天然省电） |
| WebView2 渲染 UI | SwiftUI 原生渲染 |
| PowerShell 7 写回 | Swift `FileHandle` 原位单字节写回（语义相同，已移植原版测试用例） |
| 桌面浮窗 | 灵动岛胶囊（默认）+ 可切换的桌面浮窗模式 |

## 构建与运行

需要 Xcode（Swift 6 / macOS 26 SDK）：

```bash
cd GlassIsland
scripts/build-app.sh          # swift build -c release 并组装 build/GlassIsland.app
open build/GlassIsland.app
```

测试：

```bash
swift test                    # 15 个用例：markdown 提取 + 写回安全语义
```

## 配置

首次启动会引导选择一篇 Markdown 笔记（只用这一篇）。配置保存在：

```
~/Library/Application Support/GlassIsland/config.json
```

```json
{
  "vault": "MyVault",
  "sourcePath": "/Users/you/Notes/MyVault/Inbox/Tasks.md",
  "noteFile": "Inbox/Tasks.md",
  "mode": "island"
}
```

- `vault`：Obsidian 笔记库名，用于生成 `obsidian://` 跳转链接
- `sourcePath`：笔记绝对路径（文件需已存在）
- `noteFile`：同一文件相对笔记库的路径
- `mode`：`island`（灵动岛，默认隐藏）或 `floating`（桌面浮窗，常驻）

应用自带一篇示例笔记（`~/Library/Application Support/GlassIsland/sample/Tasks.md`），首次体验可直接用；换成自己的笔记走菜单栏「选择任务笔记…」。改配置后从菜单栏重新加载，或重启应用。

## 使用

平时屏幕上**什么都不显示**（屏幕顶边有一条隐形的感应区）：

| 操作 | 方式 |
| --- | --- |
| 唤出灵动岛 | 鼠标移到**屏幕顶边中央**（菜单栏下缘附近），玻璃胶囊浮现；隐藏时屏幕上无任何可见元素 |
| 固定显示 | **点击胶囊或面板标题（Inbox 区）一下**：展开并固定，移开鼠标、点击其他任何地方都不会消失 |
| 消失 | **再点一下胶囊/标题**；或按 `Esc`（先收选项区，再收面板） |
| 临时查看 | 不点击、纯悬停展开时，移开鼠标自动收回 |
| 完成任务 | 点击任务左侧圆圈；底部「撤销」恢复最近一次 |
| 打开笔记 / 双链 | 点击标题旁 ↗ 图标或任务里的链接（仅允许 http/https/obsidian 且属于当前 vault）。当前是示例笔记时，点 ↗ 会直接弹出真实笔记库的选择框，一步切换 |
| 选项 | 标题旁 `…` 或**右键胶囊/标题**：立即刷新 / 在 Obsidian 中打开 / 从 Obsidian 选择当前笔记 / 选择文件夹 / 切换模式 / 选择单篇笔记 / 退出。（菜单栏 ☑ 图标可能被刘海挤掉，以上入口为完整替代） |
| 桌面浮窗模式 | `…` 或菜单栏切换；浮窗可拖动、可选置顶，位置自动记忆，常驻显示 |
| 选择任务源 | 三选一：**从 Obsidian 选择当前笔记**（激活 Obsidian → 打开目标笔记 → 回面板点「完成」，自动解析 vault 与路径；若未授自动化权限，自动改为弹出库内选择框，无需任何授权）、**选择文件夹**（监控其中全部 .md，勾选写回各自所属文件）、**选择单篇笔记…** |
| 刷新 | 面板右下角或菜单栏（文件/目录监视 + 2s 轮询兜底，兼容 Obsidian 原子保存） |

胶囊状态：`☑ N` 显示未完成任务数；`…` 表示尚未选择笔记。显示期间窗口层级为 statusBar（系统最上层）；完全隐藏时无任何可见元素。

### 交互架构说明（重要）

面板内容为**全量 AppKit**（原生按钮/文本/滚动），SwiftUI 仅渲染**不可交互**的玻璃背景（胶囊↔面板 Liquid Glass morph）。此前交互控件放在 SwiftUI 玻璃层内时，坐标上报与手势派发在多处不可靠（详见 git 历史），最终架构中 AppKit 控件的 hitTest/事件是系统标准行为。所有点击/动作/写回记录在 `~/Library/Application Support/GlassIsland/diag.log`，可用于功能完整性审计。

## 隐私

无网络访问、无遥测、无监听端口。仅读写你在配置里指定的那篇笔记；配置与窗口状态存于本机 `~/Library/Application Support/GlassIsland/`。

## 许可

本项目跟随上游项目交付，第三方组件见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)（markdown-it MIT、Parisienne 字体 OFL 1.1）。
