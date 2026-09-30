# Taskfold 上架 Mac App Store 手册

本手册覆盖从代码（已完成沙盒化改造）到 App Store 上架的完整流程。改造已在本仓库完成并验证的部分见 §7。

## 1. 一次性准备（首次上架前）

1. **替换 Team ID（两处占位符 `XXXXXXXXXX`）**：
   - `project.yml` → `settings.base.DEVELOPMENT_TEAM`
   - `scripts/ExportOptions.plist` → `teamID`
   - Team ID 在 [developer.apple.com → Membership 详情页](https://developer.apple.com/account#MembershipDetailsCard)（10 位字符）
   - 替换后 `make project` 重新生成工程
2. **Xcode 登录 Apple ID**：Xcode → Settings → Accounts → 添加你的 Apple ID（归档时自动签名要用来创建 Apple Development / Apple Distribution 证书）
3. **注册 App ID**：[developer.apple.com → Identifiers](https://developer.apple.com/account/resources/identifiers/list) → 注册 `com.xrw.Taskfold`（macOS）。也可以省略这步，首次 `make archive` 时 `-allowProvisioningUpdates` 会自动注册
4. **App Store Connect 新建 App**：[appstoreconnect.apple.com](https://appstoreconnect.apple.com) → 我的 App → 新建 App：
   - 平台：macOS；名称：`Taskfold`（2026-09 已核验三区无占用）；主要语言：简体中文
   - Bundle ID：`com.xrw.Taskfold`；SKU：`taskfold-mac`；访问权限：完全访问
5. **开启 GitHub Pages（隐私政策 URL）**：仓库 Settings → Pages → Deploy from a branch → 分支 `main`、目录 `/docs`。发布后隐私政策地址为：
   `https://xrw67.github.io/taskfold/privacy/`（源文件 `docs/privacy.md`）

## 2. 打包与上传

```bash
make archive    # Release 归档 → .build/Taskfold.xcarchive（自动签名）
make export     # 导出 App Store 上传包 → .build/export/Taskfold.pkg
```

上传（二选一）：

- **Transporter**（推荐）：Mac App Store 免费下载 [Transporter](https://apps.apple.com/app/transporter/id1450874784)，登录 Apple ID 后把 `Taskfold.pkg` 拖进去点「交付」
- Xcode → Organizer → Recent 归档 → Distribute App

上传后 ~10 分钟在 App Store Connect → TestFlight 出现新构建。

## 3. TestFlight 自测

macOS 也有 TestFlight（Mac App Store 下载）。ASC → TestFlight → 添加自己为内测员 → 邀请邮件激活 → 安装自测。重点验证：

- 首启出现示例数据；数据实际落在沙盒容器（`~/Library/Containers/com.xrw.Taskfold/Data/`）
- 文件 → 导入 CSV/OPML、导出 CSV/OPML/Markdown（文件面板正常弹出、可写）
- 设置 → 备份与恢复；Finder 中显示
- 快捷键（Tab/⇧Tab/回车/⌥↑↓ 等）正常

## 4. App Store Connect 表单（值可直接复制）

**版本信息**（1.0.0）：

| 字段 | 值 |
| --- | --- |
| 截图（1440×900 档，2880×1800 像素） | `docs/appstore/shot_main.png`（项目+检查器）、`shot_today.png`（今天三段）、`shot_inbox.png`（收件箱） |
| App 图标 1024×1024 | `Sources/Taskfold/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png` |
| 描述 | 见下方文案 |
| 关键词 | `待办,任务,清单,GTD,时间管理,效率,计划,提醒,专注,子任务,项目,离线,本地,无订阅,checklist,todo` |
| 技术支持 URL | `https://github.com/xrw67/taskfold` |
| 营销 URL | `https://github.com/xrw67/taskfold` |
| 隐私政策 URL | `https://xrw67.github.io/taskfold/privacy/` |
| 版权 | `© 2026 xrw` |

**副标题**（30 字内）：`GTD 待办清单 · 任务管理 · 本地优先`

**描述**：

> Taskfold 是一款类 GTD 工作流的本地优先待办应用：收集 → 整理 → 执行 → 完成。无账号、无订阅、无联网——你的数据只存在你自己的 Mac 上。
>
> 【本地优先，隐私至上】
> • 全部数据存储在本机，零网络请求、零收集、零追踪
> • SQLite 存储，万级任务依旧流畅
> • 本地自动每日备份，可随时恢复
>
> 【GTD 完整工作流】
> • 收件箱快速捕获，拖拽整理分配到项目
> • 项目与任务两级大纲，子任务任意层级嵌套，级联完成/放弃
> • 「今天」视图：逾期 / 今天 / 未来 7 天三段一目了然
> • 检查器：状态、截止时间、备注、优先级一栏看清
>
> 【键盘驱动的效率】
> • 回车续行、Tab/⇧Tab 调层级、⌥↑↓ 排序，全程不离键盘
> • ⌘1/⌘2/⌘3 快速切换收件箱 / 今天 / 项目
> • Space 完成、⌥Space 放弃，行内双击重命名
>
> 【数据完全属于你】
> • 一键导出 CSV / OPML / Markdown，随时带走
> • 支持导入 CSV / OPML，从其他工具无缝迁移

**App 隐私**：选择「未从此 App 收集数据」（Data Not Collected）。

**年龄分级**：无相关内容 → 4+。

**出口合规**：已在 Info.plist 声明 `ITSAppUsesNonExemptEncryption=false`（无加密无网络），ASC 会自动跳过问卷；如仍询问，选「App 不使用加密」。

**审核备注**（Review Notes）：

> 本应用为纯本地待办工具：无账号系统、无网络请求、无订阅内购。所有数据存储在应用沙盒内。首次启动自动创建示例数据，可直接体验全部功能（新建/完成/拖拽/导入导出）。

## 5. 提交审核

ASC → 版本 1.0.0 → 构建（选 TestFlight 验证过的）→ 存储并「提交以供审核」。首次审核通常 1-2 天。通过后可立即发布或手动发布（建议手动，掌控上线时点）。

## 6. 后续版本流程

1. `project.yml` 的 `MARKETING_VERSION` 递增（如 1.0.1）；`CURRENT_PROJECT_VERSION` 递增（2、3…）；`make project`
2. `make archive && make export` → Transporter 上传
3. ASC 新版本页填「此版本的新增内容」，提交审核

## 7. 本仓库已完成并验证的改造（2026-09-30）

- **沙盒化**：`Sources/Taskfold/Taskfold.entitlements`（app-sandbox + user-selected.read-write），xcodeproj 已挂 `CODE_SIGN_ENTITLEMENTS`；数据路径零改动——`homeDirectoryForCurrentUser` 在沙盒内自动解析到容器
- **签名**：Ad-hoc（`-`）退役，改为自动签名（`DEVELOPMENT_TEAM` 待填）；CI 走 Ad-hoc 透传（见下）
- **版本**：`MARKETING_VERSION` 1.0.0，Info.plist 版本字段变量化（`$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)`），出口合规声明内置
- **验证过**：74 个单元测试全绿；Ad-hoc+entitlements 构建的 .app 启动后数据隔离正确（容器内新建库，`~/.config/Taskfold` 真实数据未被动）；1024 图标条目编译通过；截图 3 张（2880×1800）已备
- **正式 archive/export 未跑**：等 Team ID 替换 + Xcode 登录后执行 §2

## 8. 本地开发注意事项（沙盒化的副作用）

Debug `.app`（`make xapp`）现在**同样是沙盒的**——数据在容器，与 `make run`（CLI，仍读写 `~/.config/Taskfold`）已分家：

- 日常用 `.app` 开发调试：数据在 `~/Library/Containers/com.xrw.Taskfold/Data/.config/Taskfold`
- 需要用 `.app` 直接看真实数据（非沙盒）时：
  ```bash
  make xbuild XCODEBUILD_ARGS='CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS='
  ```
- CI（GitHub Actions）app job 用 `make xbuild XCODEBUILD_ARGS='CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM='` 走 Ad-hoc 签名（不带正式证书，仍验证 entitlements 嵌入与资源打包）
