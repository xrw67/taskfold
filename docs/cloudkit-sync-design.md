# V2/V3 设计草案：iCloud（CloudKit）同步

状态：草案，未实施。目标读者：实现者。版本归属建议 V3（V2 范围已满），采纳时在 requirements §6.2/6.3 落位并更新本文状态。

## 0. 目标与非目标

**目标**
- 多台 macOS 设备间同步任务与项目（行级增量，双向）
- 本地优先不变：断网/未登录 iCloud 时应用行为与 V1 完全一致，同步是附加层
- 冲突以行级 last-writer-wins（按 `updatedAt`）自动解决，无需用户仲裁
- 恢复备份、开关同步均不丢数据

**非目标**
- 协同编辑 / 字段级合并
- 与他人共享（CloudKit shared zone）
- Windows/Web 端
- `isExpanded`（展开状态）同步——与 `showCompleted` 一样定位为**设备本地 UI 偏好**，不同步

## 1. 总体架构

```
┌─ Taskfold (SwiftUI) ──────────────────────────────┐
│ AppState ──→ SyncCoordinator（开关/状态展示/触发） │
└──────────────┬───────────────────────────────────┘
               │ 依赖
┌──────────────▼─ TaskfoldSync（新 framework target）┐
│ CKSyncEngine 封装：上行导出 / 下行应用 / 冲突决策   │
│ （CloudKit 访问全部收口在此，可协议化后单测）        │
└──────────────┬───────────────────────────────────┘
               │ 读写（TaskStore 公开 API + 同步支撑方法）
┌──────────────▼─ TaskfoldKit ──────────────────────┐
│ TaskStore (GRDB) + v3 迁移：                      │
│   pending_change / tombstone 表 + 变更捕获触发器    │
└──────────────────────────────────────────────────┘
```

- **TaskfoldKit 不 import CloudKit**：保持数据层零网络依赖（AGENTS.md 边界）。同步层独立成 `TaskfoldSync` target，仅通过 TaskStore 公开 API 与少量新增「同步支撑」方法交互
- 网络与调度全部交给系统：CKSyncEngine（macOS 14+，与项目部署目标一致）内部维护上传队列、APNs 唤醒拉取、重试与状态持久化

## 2. 数据映射

CloudKit private database，一个 custom zone `TaskfoldZone`，两种 record 类型：

| 本地 | CloudKit | 说明 |
| --- | --- | --- |
| `task` 行 | recordType `Task`，recordName = UUID 字符串 | |
| `project` 行 | recordType `Project`，recordName = UUID 字符串 | |
| `TaskItem.id` | recordName | UUID 天然全局唯一，无冲突命名 |
| `title/note` | String | |
| `projectID/parentID` | String?（UUID 字符串） | **不用 CKRecord.Reference**：避免引用完整性对上传顺序的约束（深树子任务先父后子），删除级联由本地逻辑自治 |
| `status` | String（rawValue） | |
| `dueDate` | Date? | |
| `sortIndex` | Int64 | |
| `createdAt/updatedAt` | Date | **LWW 裁决依据** |
| `isExpanded` | 不同步 | 触发器排除该列（见 §3） |

## 3. 本地变更捕获：触发器 + 待发表 + 墓碑

原则：**捕获必须完整**——任何写路径（现有 CRUD、未来的新代码、恢复备份）都不许漏。挂 Application 层 hook 会漏，SQL 触发器不会。

v3 迁移（随常规升级安装，同步开关未开也无害）：

```sql
CREATE TABLE pending_change (
  entity     TEXT NOT NULL,      -- 'task' | 'project'
  row_id     BLOB NOT NULL,
  kind       TEXT NOT NULL,      -- 'upsert' | 'delete'
  recorded_at TEXT NOT NULL,
  PRIMARY KEY (entity, row_id, kind)
) WITHOUT ROWID;

CREATE TABLE tombstone (
  entity     TEXT NOT NULL,
  row_id     BLOB NOT NULL,
  deleted_at TEXT NOT NULL,
  PRIMARY KEY (entity, row_id)
) WITHOUT ROWID;
```

触发器（以 task 为例，project 同构）：

```sql
CREATE TRIGGER task_capture_insert AFTER INSERT ON task BEGIN
  DELETE FROM tombstone WHERE entity='task' AND row_id=NEW.id;  -- 同 UUID 重生
  INSERT INTO pending_change(entity,row_id,kind,recorded_at)
    VALUES('task', NEW.id, 'upsert', datetime('now'))
    ON CONFLICT DO UPDATE SET recorded_at=datetime('now');
END;

-- 关键：UPDATE OF 列清单排除 isExpanded——纯 UI 列的变更不产生上行流量
CREATE TRIGGER task_capture_update
AFTER UPDATE OF title,note,projectID,parentID,status,dueDate,sortIndex,createdAt,updatedAt
ON task BEGIN
  INSERT INTO pending_change(entity,row_id,kind,recorded_at)
    VALUES('task', NEW.id, 'upsert', datetime('now'))
    ON CONFLICT DO UPDATE SET recorded_at=datetime('now');
END;

CREATE TRIGGER task_capture_delete AFTER DELETE ON task BEGIN
  INSERT INTO tombstone(entity,row_id,deleted_at) VALUES('task', OLD.id, datetime('now'))
    ON CONFLICT DO UPDATE SET deleted_at=datetime('now');
  INSERT INTO pending_change(entity,row_id,kind,recorded_at)
    VALUES('task', OLD.id, 'delete', datetime('now'))
    ON CONFLICT DO UPDATE SET recorded_at=datetime('now');
END;
```

要点：
- `pending_change` 主键天然去重：一行多次改动只导出最新快照（导出时按 row_id 回表取现值）
- 级联操作（`setTaskStatus` 子树、`deleteTask` 后代、`setTaskProject` 子女）全部经 SQL，触发器自动逐行捕获——现有级联实现零改动
- 每次写多一条 INSERT，万级数据下可忽略

## 4. 同步引擎（CKSyncEngine）

- `CKSyncEngine.Configuration`：privateCloudDatabase + stateStorage `.file(url)`（放 `~/.config/Taskfold/Sync/`，随库走但不进备份）
- 引擎持有 `syncState`：`.off / .running / .needsAccount / .error(String)`
- 账号变化（登出/换号）：`accountChange` 事件 → 停引擎、清本地 pending、UI 提示；换号视为全新同步（先上传本地全量到新账号的 zone）
- API 细节（事件名、delegate 方法签名）实现时以 SDK 文档为准，本文伪代码仅表意

**上行**（引擎索要变更时）：
```
nextRecordZoneChange:
  1. 取 pending_change 中 kind='delete' 的前 N 条 → CKSyncEngine 的删除变更
  2. 取 kind='upsert' 的前 N 条 row_id → 回表读当前行（已被删则跳过）
     → 组装 CKRecord（§2 映射）→ 返回给引擎
sentRecordZoneChange 成功 → 删除对应 pending_change 行
冲突（serverRecordChanged）→ 走 §5 决策，必要时以 changedKeys 策略强制覆盖
```

**下行**（fetch 事件）：
```
fetchedRecordZoneChanges:
  对每个到达的 CKRecord → §5 决策 → 应用或跳过
fetchedDatabaseChanges 收到 deletedRecordID →
  本地删行 + 撤销该行 pending upsert（防回声）+ 不写墓碑（来源即云端）
```

## 5. 冲突解决：行级 LWW

决策器为**纯函数**（放 TaskfoldKit，可单测）：

```
resolve(local: Row?, remote: Record) -> Decision
  local == nil：
    若墓碑比 remote.updatedAt 新 → 跳过（本地删除胜出，上行会补 delete）
    否则 → insert
  local != nil：
    local.updatedAt >  remote.updatedAt → skip（本地胜；本地 pending 上行时在服务端对决）
    local.updatedAt <  remote.updatedAt → update
    相等且内容一致                      → skip（**防回声关键**：云端回流的等值记录不落库，不触发 pending，避免乒乓）
    相等但内容不同（时钟偏移）           → 本地胜（skip），确定性裁决
```

- 上行到服务端遇旧版本冲突：决策器同款规则本地裁决后，若本地胜则以 changedKeys 覆盖服务端
- **列表重排的原子性**：`reorderProjects` / 行间移动已整批更新 `updatedAt`（同一 `now()`），行级 LWW 自动退化为"整表后写者胜"，两台设备各自重排不会产生交错结果。此为**必须维持的不变量**：今后任何批量重排写法都必须整批统一更新 `updatedAt`（实现时加回归测试锁定）

## 6. 应用下行写入的通道

TaskStore 新增同步支撑方法（公开，收口在 `// MARK: 同步支撑`）：

- `upsertSyncedTask(_ row: TaskItem) / upsertSyncedProject(_ row:)`：INSERT OR REPLACE 全字段，**在事务内删除该行触发的 pending_change**（远程数据落库不得回声上行）
- `applyRemoteDeletion(entity:rowID:)`：删行 + 撤 pending
- `pendingChanges(limit:) / consumePending(...) / tombstoneNewerThan(...)`：上行队列读写

回声防护双保险：等值 skip（§5）+ 落库即撤 pending（本节）。

## 7. 开关、首次开启与恢复备份

- 设置新增「iCloud 同步」Section：开关（未登录 iCloud 时禁用并提示）、状态行（引擎状态 / 待上行条数 / 上次同步时间）、「重置云端数据」按钮
- **首次开启**：确认弹窗（说明将上传全部数据到 iCloud）→ 建 zone → 全量导出（pending 本来就含全库，无需特殊"全量模式"）→ 启动引擎
- **关闭**：停引擎、UI 回到 V1 观感；数据不动。可选「删除云端 zone」
- **恢复备份**（`restoreDatabase` 在线热替换后）：清空 pending_change 与墓碑（来自备份文件的队列不可信）→ 视为本地新真相 → 若同步开着，**删除并重建 zone 全量重传**（以本地为准覆盖云端，避免备份里的旧编辑经 pending 复活）

## 8. UI 集成

- `AppState` 增加 `syncStatus`（@Observable，MainActor hop）与 `startSync/stopSync`；同步层回调经 `Task { @MainActor in ... }` 进来
- AppState 现有「写穿 + reload」模式不变——同步落库同样走 upsert 后触发 `reload()`，与本地编辑同一条刷新路径
- 同步图标/菜单暂不做，设置页展示足够（V3 可加菜单栏状态）

## 9. 限制与已知取舍

| 限制 | 说明 / 缓解 |
| --- | --- |
| 行级 LWW，无字段合并 | 两设备同时改同一行的不同字段，后写整行胜出。GTD 单人场景可接受 |
| 设备时钟偏移 | 依赖系统 NTP；相等时间戳按"内容一致 skip / 不一致本地胜"确定性兜底 |
| 大规模重排流量 | 整批 updatedAt 换来原子性，代价是一次重排 = N 行上行。任务量级（千级）无感 |
| iCloud 配额 | private DB 计入用户配额；不含二进制大字段（无附件功能），占用 ≈ 库大小 |
| 隐私 | private DB 开发者服务器不可见；如需更强可将 title/note 放 encryptedValues（同账号多设备可用），默认不启用 |
| 单平台 | 仅 macOS；未来 iOS 端复用同一映射即可 |

## 10. 测试计划

**TaskfoldKitTests（纯 SQLite，全部可自动化）**
- 触发器完备性：add/update/setTaskStatus（级联）/deleteTask（级联）/setTaskProject（级联）/dropTask/重排 → pending 与墓碑断言；`isExpanded` 变更**不**产生 pending（回归锁定 §3 的 UPDATE OF 列表）
- 决策器：§5 全部分支（含等值内容一致 skip、墓碑更新跳过、相等不一致本地胜）
- upsert 撤 pending：远程落库后队列无残留（防回声）
- 批量重排不变量：整批 updatedAt 一致 → 不会交错

**TaskfoldSyncTests（引擎协议化后注入 fake）**
- 上行：pending → record 组装字段映射全对；删除走墓碑路径
- 下行：fetch 应用顺序、错误重试不丢队列

**手动**：两台真机（或两用户目录）双开验证：编辑/删除/级联/重排/离线队列/开关/恢复备份七场景。

## 11. 里程碑

1. **M1 数据基建**：v3 迁移（队列/墓碑/触发器）+ 决策器纯函数 + TaskStore 同步支撑方法 + 上述单测
2. **M2 上行**：TaskfoldSync target（Package.swift + project.yml 双体系）+ CKSyncEngine 接线 + 状态持久化
3. **M3 下行闭环**：fetch 应用 + 冲突对决 + 回声防护双测
4. **M4 产品化**：设置开关/状态/重置、恢复备份交互、账号变化处理
5. **M5 双机验证**：七场景手动清单 + 节流观察
