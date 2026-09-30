# AGENTS.md — Taskfold 工作区说明

类 OmniFocus 的 macOS 本地待办应用：SwiftUI + GRDB 7（SQLite），本地优先无联网，GTD 工作流。macOS 14+，Swift 6 严格并发。代码注释与 UI 文案均为中文。

## 构建与测试（重要：工具链坑）

系统 `xcode-select` 指向 CLT，但 CLT 缺少 SwiftUI/swift-testing 宏插件，**裸跑 `swift build`/`swift test` 会失败**。必须通过 Makefile（内部已 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`）：

```bash
make build      # swift build
make test       # 单元测试（swift-testing，非 XCTest）
make run        # 运行裸可执行（无 bundle）
make bench      # 存储基准（release）

make project    # 改 project.yml 后重新生成 xcodeproj（xcodegen）
make xbuild     # xcodebuild 构建 .app
make xtest      # xcodebuild 跑测试
make xapp       # 启动 .app 产物
```

两套构建体系并存：Swift Package 用于快速 CLI 迭代；`Taskfold.xcodeproj` 用于 IDE 调试与分发。**不要手改 pbxproj**——改 `project.yml` 后 `make project`。`Sources/*/Info.plist` 由 xcodegen 生成且已在 Package.swift 中 exclude，勿手动提交（见 .gitignore）。

CI（GitHub Actions，`.github/workflows/ci.yml`）在 macos-26 runner 上跑两个 job：`make build`+`make test`（SwiftPM 全量构建+swift-testing），以及 `make xbuild`（直接构建已提交的 xcodeproj，不装 xcodegen 重新生成，避免版本漂移）。

## 架构与边界

- `Sources/TaskfoldKit/` — 数据层框架，**禁止引入 UI 依赖**：
  - `Models.swift`（TaskItem/ProjectItem/ItemStatus）、`Store.swift`（TaskStore：GRDB CRUD、迁移、徽章、大纲编辑操作）
  - `Backup.swift`（SQLite online backup，在线热替换）、`Export.swift`（CSV/OPML/Markdown）
- `Sources/Taskfold/` — SwiftUI 应用：`TaskfoldApp`（入口+菜单命令）、`AppState`（`@MainActor @Observable` 状态容器，视图状态+数据缓存+动作都在这里）、`KeyboardRouter`、`Views/`（三栏：Sidebar/Outline/Inspector/Settings）
- `Sources/Bench/` — 存储基准；`Tests/TaskfoldKitTests/` — swift-testing 单测
- TaskStore 用 DatabaseQueue 串行执行，V1 主线程同步调用即可（万级数据查询 <30ms）；WAL 模式；迁移用 GRDB DatabaseMigrator

## 关键设计决策（勿推翻）

- **GRDB 而非 SwiftData**：CLT 下 SwiftData 宏插件无法编译；性能远超 NFR-1（见 README「M0 决策记录」）
- **KeyboardRouter 用 NSEvent local monitor**：无修饰键 Tab/⇧Tab 会被 macOS 焦点循环消费，`.onKeyPress` 依赖 first responder——local monitor 在事件分发前接管，任意焦点有效，文本输入时放行
- App 为 **Ad-hoc 签名**（`CODE_SIGN_IDENTITY: "-"`），本地分发无需开发者账号

## 数据与运行时

- 数据库：`~/.config/Taskfold/Taskfold.sqlite`，备份在同目录 `Backups/`；`make run` 与 `.app` **共用同一数据库**（测试破坏性改动时注意）
- 应用原名 MyFocus，2026-09 改名 Taskfold：启动时一次性迁移旧数据（`~/.config/MyFocus/` 优先，含 Backups 与备份文件名前缀改写；更早的 `~/Library/Application Support/MyFocus/` 兜底；UserDefaults 从旧 bundle 域搬移）
- 空库首启会创建示例数据；`showCompleted` 等用户偏好持久化在 UserDefaults

## 改动前必读

- `docs/requirements.md` — 需求文档：V1 范围（5 个核心功能）、V2 路线（§6.2）、明确不做的清单（§2）。新增功能先对照此文档确认版本归属
- `README.md` — 当前状态表、快捷键表、项目结构
