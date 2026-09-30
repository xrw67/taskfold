# MyFocus

类 OmniFocus 的 macOS 本地待办管理应用。本地优先（SQLite，无账号无联网）、GTD 工作流（收集 → 整理 → 执行 → 完成）、SwiftUI 原生界面。

需求文档：[docs/requirements.md](docs/requirements.md)

## 当前状态：V1 完成 ✅

V1 范围（需求文档 6.1）全部实现：任务与项目（含一层子任务、级联完成/放弃）、收件箱（捕获/整理/拖拽分配）、截止日期与「今天」三段视图（逾期/今天/未来 7 天）、检查器、本地存储与搜索。

| 里程碑项 | 状态 | 说明 |
| --- | --- | --- |
| 存储选型（GRDB vs SwiftData） | ✅ M0 | **GRDB 7**（详见下文决策记录） |
| 数据层（CRUD/级联/收件箱/今天窗口/搜索/徽章/大纲编辑操作） | ✅ | `Sources/MyFocusKit` |
| 单元测试 | ✅ | 27 个测试全部通过（swift-testing） |
| 三栏窗口（侧边栏 / 大纲 / 检查器） | ✅ | `Sources/MyFocus`；检查器为自定义面板风（状态圆点头 + 摘要头部、彩色状态胶囊、图标属性行、圆角备注） |
| 大纲键盘编辑（回车续行/Tab/⇧Tab/⌥↑↓） | ✅ | 见下表 |
| 拖拽分配项目（INB-3，子任务跟随） | ✅ | 拖任务行到侧边栏项目/收件箱 |
| 项目拖拽排序 | ✅ | 侧边栏拖动项目行调整顺序（原生 onMove） |
| 日期快捷按钮（今天/明天/+1周/清除） | ✅ | 检查器·日历弹层（系统迷你月历，改日期保留时间分量） |
| 设置窗口（⌘,：默认截止时刻 + 库路径） | ✅ | `SettingsView` |
| 搜索高亮 + ⌘F 聚焦 | ✅ | 命中段黄色高亮，Esc 清空 |
| 首启示例数据 | ✅ | 空库自动创建，可正常删除 |
| 备份与恢复（DATA-1） | ✅ | 当天首次启动自动备份；「文件 → 立即备份」；设置中管理/恢复（在线热替换，无需重启）；默认保留 20 份可调 |
| 导出 CSV / OPML / Markdown（DATA-2） | ✅ | 「文件 → 导出为」；CSV 带 BOM（Excel 中文友好）、OPML 可导入大纲工具、Markdown 为 GFM 任务列表（Obsidian/GitHub 直接渲染） |

**已知偏差**：DT-2「即将到期窗口可配置」V1 固定为"今天内"，窗口配置移至 V2。

## 快捷键

| 键 | 功能 |
| --- | --- |
| ⌘N | 新建任务（当前区域） |
| ⌘1 / ⌘2 / ⌘3 | 收件箱 / 今天 / 第一个项目 |
| Space / ⌥Space | 完成 / 放弃（选中任务） |
| ⌘⌫ | 删除选中任务（连同全部子任务） |
| 回车 | 在选中任务下方插入并进入编辑（编辑中回车=确认并续行） |
| Tab / ⇧Tab | 缩进为上一行的子任务（任意层级）/ 提升一级，子树自动跟随 |
| ⌥↑ / ⌥↓ | 同级内上移 / 下移 |
| ↑ / ↓ | 上/下移动选中（按可见行顺序跨层级，自动滚动；不依赖列表焦点，无选中时 ↓ 选首行、↑ 选末行） |
| → / ← | 展开 / 折叠子任务；已展开时 → 进入第一个子任务，无子任务时 ← 选中父任务 |
| 双击 | 行内重命名（Esc 取消） |
| ⌘F | 聚焦搜索（Esc 清空并退出） |
| ⌘⌥I | 显示/隐藏检查器 |

大纲快捷键（Tab/⇧Tab/回车/⌥↑↓/↑↓←→/Space/⌥Space）由应用级键盘监听（`KeyboardRouter`，NSEvent monitor）接管：**不依赖列表焦点**，任意焦点状态下都有效；文本输入时自动放行。子任务支持**任意层级嵌套**，完成/放弃/恢复和删除会递归作用于整棵子树。

## 开发环境

系统 `xcode-select` 指向 Command Line Tools，但 CLT 缺少 SwiftUI/SwiftData/swift-testing 的宏插件。本机装有完整 Xcode 27，所有构建命令统一通过 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 使用它（已封装在 Makefile，免 sudo 切换）。

两套构建体系并存：

```bash
# Swift Package 工作流（快速 CLI 迭代）
make build    # 构建
make test     # 单元测试
make run      # 运行应用（裸可执行，无 bundle）
make bench    # 存储基准测试

# Xcode 工作流
open MyFocus.xcodeproj   # 用 Xcode 打开（App scheme 可调试、断点、Instruments）
make project             # 修改 project.yml 后重新生成 xcodeproj
make xbuild              # xcodebuild 构建 .app（.build/xcode/Build/Products/Debug/MyFocus.app）
make xtest               # xcodebuild 跑测试
make xapp                # 启动 xcodebuild 产物 .app
```

- `MyFocus.xcodeproj` 由 [xcodegen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成；改目标/依赖/签名请改 `project.yml` 再 `make project`，不要手改 pbxproj。
- App 目标当前为 **Ad-hoc 签名**（本地运行无需开发者账号）；上架或 Developer ID 分发时在 `project.yml` 中调整签名配置。
- `make run` 与 `.app` 共用同一个数据库（`~/Library/Application Support/MyFocus/MyFocus.sqlite`）。

数据存储在 `~/.config/MyFocus/MyFocus.sqlite`（WAL 模式），自动备份在同目录 `Backups/`。旧版 `~/Library/Application Support/MyFocus/` 的数据会在启动时自动迁移（一次性，迁移后旧目录清理）。

## M0 决策记录：为什么选 GRDB 而不是 SwiftData

1. 默认 CLT 工具链下 SwiftData 的 `@Model` 宏插件（SwiftDataMacros）不存在，根本无法编译。
2. GRDB 基准（1 万条任务，release 构建，2026-09-28, Apple Silicon）：

   | 操作 | 耗时 |
   | --- | --- |
   | 单事务插入 10k | 128 ms |
   | 查询 active 按截止排序 | 28 ms |
   | 计数（索引过滤） | 0.7 ms |
   | 全量水合 10k 行 | 25 ms |
   | 更新 1000 行（单事务） | 7.6 ms |
   | 删除 1000 行（单事务） | 2.3 ms |

   远优于需求 NFR-1（搜索 < 100ms）。
3. GRDB 附带 DatabaseMigrator 迁移体系、后续 FTS5 全文检索能力；SwiftData 在 Swift 6 严格并发下生态尚不成熟。

## 项目结构

```
MyFocus/
├── docs/requirements.md      # 需求文档（V1 = 5 个核心功能）
├── Package.swift             # Swift Package：MyFocusKit / MyFocus / Bench / Tests
├── project.yml               # xcodegen 描述 → 生成 MyFocus.xcodeproj
├── MyFocus.xcodeproj/        # Xcode 工程（App/框架/Bench/测试 四目标）
├── Sources/
│   ├── MyFocusKit/           # 数据层（无 UI 依赖）
│   │   ├── Models.swift      # TaskItem / ProjectItem / ItemStatus / TodaySection
│   │   └── Store.swift       # TaskStore：GRDB CRUD、查询、徽章计数、迁移
│   ├── MyFocus/              # 应用（SwiftUI）
│   │   ├── MyFocusApp.swift  # 入口 + 菜单命令（⌘N/⌘1-3/⌘⌫/⌘⌥I）
│   │   ├── AppState.swift    # @Observable 状态容器（视图状态 + 数据缓存 + 动作）
│   │   └── Views/            # MainView（三栏 HSplitView）/ Sidebar / Outline / Inspector / Settings
│   └── Bench/                # 存储基准测试
└── Tests/MyFocusKitTests/    # swift-testing 单元测试
```

## 下一步（V2，见需求文档 6.2）

标签、旗标、推迟日期（Defer）、顺序/并行项目、重复任务、系统提醒通知、Forecast 完整版（琴键+月历）、全局 Quick Entry、Quick Open、自然语言日期、导入（CSV/OPML）、富文本备注、文件夹、批编辑、撤销/重做；以及 V1 遗留的「即将到期窗口可配置」「行间拖拽排序」。（多层级嵌套、备份与导出已提前实现）
