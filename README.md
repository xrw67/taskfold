# MyFocus

类 OmniFocus 的 macOS 本地待办管理应用。本地优先（SQLite，无账号无联网）、GTD 工作流（收集 → 整理 → 执行 → 完成）、SwiftUI 原生界面。

需求文档：[docs/requirements.md](docs/requirements.md)

## 当前状态：M0 完成 ✅

| 里程碑项 | 状态 | 结论 |
| --- | --- | --- |
| 存储选型（GRDB vs SwiftData） | ✅ | **GRDB 7**（详见下文决策记录） |
| 数据层（项目/任务/子任务 CRUD、级联、收件箱、今天窗口、搜索、徽章） | ✅ | `Sources/MyFocusKit` |
| 单元测试 | ✅ | 14 个测试全部通过（swift-testing） |
| 三栏窗口骨架（侧边栏 / 大纲 / 检查器） | ✅ | `Sources/MyFocus` |
| CRUD 持久化闭环 | ✅ | 应用启动验证通过 |

## 开发环境

系统 `xcode-select` 指向 Command Line Tools，但 CLT 缺少 SwiftUI/SwiftData/swift-testing 的宏插件。本机装有完整 Xcode 27，所有构建命令统一通过 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 使用它（已封装在 Makefile，免 sudo 切换）。

```bash
make build    # 构建
make test     # 单元测试
make run      # 运行应用
make bench    # 存储基准测试
```

数据存储在 `~/Library/Application Support/MyFocus/MyFocus.sqlite`（WAL 模式）。

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
├── Sources/
│   ├── MyFocusKit/           # 数据层（无 UI 依赖）
│   │   ├── Models.swift      # TaskItem / ProjectItem / ItemStatus / TodaySection
│   │   └── Store.swift       # TaskStore：GRDB CRUD、查询、徽章计数、迁移
│   ├── MyFocus/              # 应用（SwiftUI）
│   │   ├── MyFocusApp.swift  # 入口 + 菜单命令（⌘N/⌘1-3/⌘⌫/⌘⌥I）
│   │   ├── AppState.swift    # @Observable 状态容器（视图状态 + 数据缓存 + 动作）
│   │   └── Views/            # MainView（三栏 HSplitView）/ Sidebar / Outline / Inspector
│   └── Bench/                # 存储基准测试
└── Tests/MyFocusKitTests/    # swift-testing 单元测试
```

## 下一步（V1，见需求文档 6.1）

- 大纲键盘编辑补全：Tab/⇧Tab 缩进建子任务、⌥↑↓ 移动行、行间拖拽
- 逾期红色分区标题、「今天」视图按项目归属展示优化
- ⌘F 聚焦搜索、裸键编辑
- 首次启动示例数据
- 重命名项目的就地编辑（当前为弹窗）
