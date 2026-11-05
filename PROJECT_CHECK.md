# GlassIsland 项目检查手册（交接文档）

> 供新一轮会话/检查者使用。本文是项目当前状态的唯一权威快照：路径、架构、功能清单、检查方向、已知坑与审计手段。

## 项目身份

- **项目根**：本机克隆目录下的 `GlassIsland/`（git clone 本仓库即可，路径以实际克隆位置为准）
- **GitHub**：`UnderTale-Vertin/GlassIsland`（main 分支）
- **来源**：[Wang060919/ObsidianGlassTasks](https://github.com/Wang060919/ObsidianGlassTasks) 的 macOS 移植（灵动岛形态），引用与第三方许可见 `README.md` 顶部与 `THIRD-PARTY-NOTICES.md`
- **平台**：macOS 26（Liquid Glass），Swift 6.3 / SDK 26.5，SPM 工程，零第三方 Swift 依赖（markdown-it 走 JavaScriptCore）
- **运行方式**：`scripts/build-app.sh` → `build/GlassIsland.app`；当前用户本机正在运行

## 文件地图

| 文件 | 职责 |
| --- | --- |
| `Package.swift` | SPM：executable `GlassIsland` + 测试 target，macOS 14+ |
| `Sources/GlassIsland/main.swift` | 入口：`.accessory`（无 Dock 图标） |
| `AppDelegate.swift` | 菜单栏 ☑、三种选源流程（Obsidian 窗口标题/库内兜底面板/文件夹/单篇）、模式切换、诊断门控 `GLASSISLAND_DIAG=1/2` |
| `IslandController.swift` | **窗口层**：IslandPanel(statusBar 级)、顶边隐形热点条(400×6)、FlippedContainerView 根视图、标题点击区 ToggleZoneView、refit 布局、点击审计 |
| `GlassBackground.swift` | SwiftUI **纯视觉**玻璃背景：capsule↔panel morph（glassEffectID），`hitTest=nil` 不可交互；旧系统回退 ultraThinMaterial |
| `PanelContentView.swift` | **全量 AppKit 面板内容**：头部(Inbox 花体/计数/↗/…)、内联选项区、任务列表(NSScrollView)、圆圈勾选、撤销、状态栏、刷新、Esc 处理、高度回调 |
| `InlineText.swift` | markdown-it 行内 HTML → NSAttributedString（a/strong/em/code/s/br + 实体解码） |
| `TaskStore.swift` | 数据协调：读取/提取/勾选写回/撤销/通知；文件夹源聚合（TaskItem.filePath 按文件写回）；示例笔记引导切换 |
| `TaskWriter.swift` | **原版 Action.ps1 语义**：原位单字节翻转 `[ ]`↔`[x]`，保 BOM/CRLF；行漂移找唯一同名行、重名/状态不符拒写 |
| `MarkdownBridge.swift` | JavaScriptCore 跑 `Resources/vendor/markdown-it.min.js` + `tasks.js`（原仓库 tasks.mjs 适配），提取与 Windows 版逐字节同语义 |
| `NoteWatcher.swift` | 目录级 DispatchSource（防原子保存孤儿 fd）+ 按路径重开 + 2s stat 轮询 + 自写回静默 |
| `ObsidianSupport.swift` | 窗口标题解析（支持笔记名含 " - "）、obsidian.json vault 注册表、库内笔记定位、activateObsidian、AppleEvent -1743 权限探测 |
| `OpenLink.swift` | 链接校验（Action.ps1 open 语义）：仅 http/https/obsidian://open 且 vault 匹配、无多余参数；validate 纯函数可测 |
| `Config.swift` | `~/Library/Application Support/GlassIsland/config.json`；**decodeIfPresent 逐字段容错**（缺键不炸） |
| `DiagLog.swift` | 始终开启的审计日志 → `~/Library/Application Support/GlassIsland/diag.log` |
| `Res.swift` | 资源定位：兼容 SPM 开发布局与组装后的 .app（Bundle.main/module 双查），注册 Parisienne 花体字体 |
| `IslandModel.swift` | 交互状态机（visible/expanded/pinned/showOptions/mode），**有单元测试锁定** |
| `Tests/GlassIslandTests/` | 36 条：Extraction(5) / WriteBack(10) / IslandModel(5) / Obsidian+Folder(6) / Regression(10: Config 解码/OpenLink/InlineHTML/双链路径) |
| `scripts/build-app.sh` | release 构建 + 组装 .app（含资源、ad-hoc 签名） |
| `AGENT_TASK.md` | 工作日志（gitignore，不入库）；`README.md` 用户文档 |

## 用户需求 → 实现对账

1. **macOS 适配 + 灵动岛形态**：顶部胶囊、悬停展开、显示时 statusBar 最上层、隐藏时零可见元素 ✅
2. **点击固定 / 再点消失**：点胶囊或标题（Inbox 区）；列表中部点击无动作（用户明确要求）✅
3. **点击任务笔记直接进 Obsidian 选择笔记或文件夹**：「从 Obsidian 选择当前笔记」（窗口标题魔法解析）；未授自动化权限自动兜底为库内选择框；「选择文件夹」聚合监控 ✅
4. **数据语义与 Windows 版一致**：提取/写回/撤销/双链/自动同步（36 测试）✅

## 检查方向

### A. 自动化检查（先跑）

```bash
cd <项目根>
swift build            # 零 error 零 warning
swift test             # 36/36 全绿
pgrep -lf "MacOS/GlassIsland"          # 恰 1 个实例
tail -3 ~/Library/Application\ Support/GlassIsland/diag.log   # launch build= 行
```

### B. 交互验收（10 步，每步有日志对账）

| # | 操作 | 预期 | diag.log 证据 |
| --- | --- | --- | --- |
| 1 | 悬停屏幕顶边中央 | 胶囊浮现 | — |
| 2 | 点胶囊 | 展开并固定 | `toggleZone click pinned=true` |
| 3 | 移开鼠标 | 保持不消失 | （无 hide 记录） |
| 4 | 再点标题 | 完全消失；再悬停点标题恢复 | `toggleZone click pinned=false` |
| 5 | 点 `…` | 内联选项区展开 | `icon 选项` |
| 6 | 「从 Obsidian 选择当前笔记」 | 自动切 Obsidian | `activateObsidian …` |
| 7 | Obsidian 打开笔记→点「完成」 | 自动配好 vault/路径 | `obsidian pick → …`；未授权则弹库内面板（`vault panel pick → …`） |
| 8 | 点任务圆圈 | Obsidian 中该行变 `[x]` | `circle click` + `toggle OK …` |
| 9 | 点「撤销」 | `[ ]` 还原 | `label 撤销` + `undo OK …` |
| 10 | 右键标题 | 选项区展开 | `toggleZone`（与左键同串，日志不可区分；右键代码路径 `rightMouseDown` 已确认存在） |

### C. 数据安全检查（重点）

- 勾选只翻转 1 字节：`od -c` 对比前后（WriteBackTests 已锁定 10 条：BOM/CRLF 保留、行漂移、重名拒写、状态不符拒写、非任务行拒写、缺文件报错）
- 只读写配置指定的源；文件夹模式跳过 `.` 隐藏目录（.obsidian 不误报）
- 链接白名单：javascript:/ftp:/外库 obsidian 链接全部拒绝（OpenLinkTests）
- 无网络/遥测/端口监听

### D. 边界与健壮性

- 配置文件缺键/损坏 → 不炸，逐字段回退默认（RegressionTests.testMissingKeysFallBackToDefaults）
- 笔记被 Obsidian 原子保存（temp+rename）→ 2s 内仍能刷新（目录监视）
- 笔记被删/移动 → "Note unavailable" 状态，恢复后自动重连提示
- 菜单栏 ☑ 可能被刘海挤掉 → `…` 与右键为完整替代入口

### E. 已知坑清单（历史教训，检查时重点盯）

1. **三层翻转坐标系**：root(已 FlippedContainerView)/PanelContentView/TaskRowView 均 isFlipped；任何新增 NSView 必须确认坐标系
2. **NSHostingView 不做 hitTest 包含预检**：子视图 hitTest 必须 `bounds.contains(convert(...))` 自查（ToggleZoneView 现已正确）
3. **SwiftUI 玻璃层内交互控件不可靠**：手势被吞/坐标错位——新增交互一律走 AppKit，SwiftUI 只做视觉
4. **SwiftUI Menu / NSMenu.popUp 在非激活面板弹不出**：一切菜单用内联选项区
5. **合成 Codable 不吃默认值**：Config 新字段必须 decodeIfPresent
6. **假重启**：必须 `pkill -9` + 确认 pgrep 为空再 `open`；新构建验证看 diag.log `launch build=` 行
7. **NSTextField.action 属性遮蔽**：子类闭包回调命名用 onTap（ClickableLabel）

### F. 遗留事项

- GitHub 仓库当前**私有**；是否转公开/删除由用户定夺
- 开机自启（SMAppService）未做（计划内可选项，用户未点头）
- 玻璃 morph 视觉手感与原生控件外观（AppKit 化的代价）待用户最终认可

## 检查记录

### 2026-11-04（A→F 全面检查）

- **A ✅**：独立 scratch 干净构建 0 warning 0 error；`swift test` 36/36；单实例；launch 行齐全
- **B ⚠️**：第 2/4/5/6 步有日志证据（11/11/13/3 次）；第 7/8/9 步 **0 证据**（`obsidian pick`/`circle click`/`toggle OK`/`undo OK` 等语句源码存在，但日志 356 行内从未出现，交互全部集中在 11-01 当天）；已升级至 F 节
- **C ✅**：Swift/JS 双侧无网络与遥测 API；OpenLink 白名单 http/https/obsidian + vault 匹配；写回 10 条测试锁定
- **D ✅**：Config `decodeIfPresent` ×7；NoteWatcher dir/file 双 DispatchSource + 轮询；刘海替代入口在
- **E ✅**：7 坑代码侧全部落实（isFlipped ×3 / ToggleZone 预检 / 玻璃层不可交互 / 无 popUp / decodeIfPresent / 假重启 / onTap）；坑 6 本次踩中变体——运行实例原为 11-01 07:25:33 构建，落后 HEAD 收尾提交
- **部署修正**：`pkill -9` + `scripts/build-app.sh`（release 零警告）+ 重开，新实例 `launch build=11-04 02:33:41 mode=island` 实证，HEAD（bd0c33b）已部署运行
- 仓库可见性 `gh` 实证：PRIVATE，与本文一致
- **10 步验收缺口（2026-11-04 检查实证）**：第 7/8/9 步（选源完成/勾选写回/撤销）在日志期内 **0 次真实执行**——核心数据路径目前仅单元测试背书，无端到端实测；第 1/3 步依赖人工观察（面板收起无日志）；第 10 步与左键共用日志串不可区分。待用户按 B 表补走 7→8→9 并对账 diag.log
