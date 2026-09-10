# SAOIF 脚本框架设计

- 日期：2026-09-10
- 状态：已确认，待实施
- 分支：`spike/framework-skeleton`（验证）→ 后续实施分支

## 1. 背景与目标

当前项目只有「钓鱼」一个功能（`脚本/tasks/fishing.lua`，约 300 行），但 README 规划了公告板、活动、每日任务等多项功能，目标是 **7x24 挂机**。

按现状每加一个功能，摩擦都在增加：

| 现状问题 | 证据 |
|---|---|
| 加功能要改 3 处且靠人工同步 | `saoif.lua` 的 `require`、`dispatcher.register`、`界面/saoif.ui` 的 `<选项>`；`saoif.lua` 注释自己写着「必须与 tasks 模块的 name 一致」 |
| 特征数据埋在逻辑里 | `fishing.lua` 顶部 `DO1`~`DO4`/`TARGET` 比色串，改一个点要编辑代码，无法在界面调 |
| 参数默认值写两遍 | `readConfig` 里的 `def` 参数与 `界面/saoif.ui` 的 `默认值` 各写一份，会漂移 |
| 单文件职责过多 | `fishing.lua` 混了配置读取、状态机、HUD、图像查找四件事 |
| 没有任务生命周期 | HUD 显示、停止检查、统计、异常恢复每个任务都要重写 |
| 没有调度能力 | 一次只能跑一个功能，无法「每日任务做完再钓鱼」 |

**目标**：建立一套可扩展、可复用的框架，使新增一个功能只需「写一个目录 + 一个参数页 + 清单加一行」。

**非目标**：不做多设备协同、不做远程 GUI、不做云端配置同步。

## 2. 已确认的设计决策

| 决策 | 选择 | 说明 |
|---|---|---|
| 运行模型 | **到期时间调度器** | 每个任务有 `nextRun`，主循环挑最早到期的启用任务执行。参考项目同款 |
| 配置界面 | **每个任务一个静态 `.ui`** | 保留 XML 界面的精细样式 |
| 状态持久化 | **需要** | `nextRun` 等运行时状态落盘，脚本重启后延续 |
| 错误恢复 | **分类处理** | 可恢复错误重排本任务，需人工介入的错误停止脚本 |
| 平台 | 懒人精灵（lrjl）Lua，Android | 分辨率基准 1280x720 横屏 |

## 3. 平台行为验证结论（spike 实测）

2026-09-10 在真机上通过 `脚本/spike/probe.lua` 实测，以下结论是设计的前提：

| 结论 | 实测证据 |
|---|---|
| `getWorkPath()` 可写 | 返回 `/data/local/tmp/lrwork/com.nx.nxprojit/script/work`；`writeFile`/`readFile`/`fileExist`/`mkdir` 均可用 |
| `jsonLib.encode`/`decode` 可用 | 状态表编码后写盘、读回、解码，字段值还原正确 |
| **`<窗口 配置文件="x.config">` 自动持久化所有控件值** | 4 类控件全部验证：输入框 `空→标记`、数字框 `45→88`、多选框 `true→false`、下拉框 `0→2` |
| `showUI` 阻塞并在关闭时返回配置 JSON | `showUI` 返回值为各页各控件值的 JSON 字符串 |
| 事件回调可用闭包 upvalue 传用户意图 | 回调中 `action = "config"`，`showUI` 返回后读到该值 |
| **`onload` 内调 `closeWindow` 关不掉窗口** | 日志显示 `showUI` 已返回且脚本继续，但窗口仍盖在屏幕上 |

**关键推论**：
1. 每个任务的参数页只需绑一个自己的 `配置文件`，**不需要手写配置读写**。
2. 界面流转必须由**用户点击**驱动，不能用 `onload` 自动关窗来跳过步骤。
3. 「主界面 → 任务参数页 → 返回主界面」用**关一个再开一个的循环**实现，不能嵌套开子窗口。

## 4. 架构分层

```
表现层   界面/*.ui + 脚本/ui/       窗口流程、HUD、事件路由
框架层   脚本/core/                 调度、状态、配置、任务协议、日志、异常
能力层   脚本/vision/ 脚本/game/    图色识别、规则对象、页面导航、共享组件
业务层   脚本/tasks/<任务>/         每个游戏功能一个目录
```

依赖方向单向向下：`tasks` 依赖 `core`/`vision`/`game`，反向不依赖。`core` 不依赖 `tasks`（任务清单由入口注入）。

## 5. 目录结构

```
脚本/
  saoif.lua                  入口：装配任务清单 → 主界面 → 调度主循环
  core/
    logger.lua               日志（已有，增强：任务标签、分级）
    registry.lua             任务注册表：require 清单里的模块并建立 name → 任务 的查找（取代 dispatcher.lua）
    task.lua                 任务协议校验与默认值填充
    scheduler.lua            到期调度：挑最早到期任务、跑完重算 nextRun
    state.lua                运行时状态持久化（getWorkPath()/saoif_state/state.json）
    settings.lua             每任务调度设置（启用/优先级/间隔）的读写
    exception.lua            错误分类 → 处理策略
  vision/
    pixel.lua                比色（从 core/ 移入）
    rule.lua                 规则对象：color / image / click + 通用动作
    image.lua                找图封装
    ocr.lua                  【占位】OCR 封装
  ui/
    window.lua               showUI 阻塞封装 + 事件路由（upvalue 传 action）
    hud.lua                  HUD 封装（从 fishing.lua 抽出）
  game/
    page.lua                 【占位】页面图 + BFS 寻路
    navigate.lua             【占位】通用导航：回主界面 / 关弹窗 / 等加载
  component/                 【占位】跨任务共享能力（战斗 / 购买 / 领奖 / 切号）
  dev/
    selfcheck.lua            纯逻辑自检（不需要游戏在跑）
  tasks/
    index.lua                任务清单：纯数据，列出各任务模块路径（新增任务只改这里一行）
    fishing/
      task.lua               任务主逻辑
      assets.lua             特征与坐标常量（DO1~DO4 / TARGET / CLONE_IMG）
      config.lua             参数读取与默认值（单一来源）
      test.lua               单任务调试入口
    daily/                   【占位】每日任务
    board/                   【占位】公告板
    activity/                【占位】活动

界面/
  saoif.ui                   主界面：任务下拉框 + 调度面板 + 配置/自检/运行
  tasks/
    fishing.ui               钓鱼参数页（从 saoif.ui 迁出）
    daily.ui                 【占位】
    board.ui                 【占位】
    activity.ui              【占位】
```

**占位约定**：空目录放一个 3 行的 `README.md` 说明该目录放什么（git 不跟踪空目录，且这样能自解释架构）。

## 6. 任务协议

任务模块返回一张表，`core/task.lua` 负责校验与补默认值。

```lua
-- 脚本/tasks/fishing/task.lua
return {
    name     = "fishing",              -- 唯一键：state.json 的键、清单引用名
    title    = "钓鱼",                  -- 界面显示名
    ui       = "tasks/fishing.ui",     -- 参数页（相对 界面/）
    enabled  = true,                   -- 默认启用
    priority = 5,                      -- 越小越优先（仅当到期时间相同时决胜）
    interval = { success = 1, failure = 1 },  -- 单位：小时

    limitTime  = 0,   -- 单轮软超时（秒），0 = 不限
    limitCount = 0,   -- 单轮目标次数，0 = 不限

    readConfig = function(handle) ... end,  -- 从参数页读配置，返回 table
    run        = function(cfg, ctx) ... end, -- 任务主逻辑
}
```

**`run` 的约定**：
- 自行循环直到达成 `limitCount` 或超出 `limitTime`，然后正常返回。
- 每轮循环须检查 `ctx.shouldStop()`（全局停止信号），为真时尽快返回。
- 用 `ctx.hud:update(状态文字)` 更新 HUD，不自己管理 HUD 句柄。
- 需要中止时 `error(ex.recoverable("原因"))`；正常跑完直接 `return`。

**`ctx` 提供**：`shouldStop()`、`hud`、`stats`（本轮计数）、`taskName`。

## 7. 调度器

`core/scheduler.lua` 主循环：

```lua
local scheduler = require("core.scheduler")
scheduler.setup(tasks)                 -- 注入清单（来自 tasks/index.lua）

while not scheduler.shouldStop() do
    local task = scheduler.nextDue(os.time())
    if task then
        scheduler.runOnce(task)        -- 内部 pcall，异常不冒泡到主循环
    else
        sleep(scheduler.idleSleepMs()) -- 睡到最近一个到期时间，或上限
    end
end
```

**到期挑选**：遍历启用任务，取 `nextRun <= now` 中 `nextRun` 最小者；`nextRun` 相同则 `priority` 小者胜。

**跑完结算**（`onFinish`）：

| 结果 | nextRun | 其他 |
|---|---|---|
| 正常返回 | `now + successInterval` | `failureStreak = 0`，`successCount += 1` |
| `ex.recoverable` | `now + failureInterval` | `failureStreak += 1`，记 WARN 日志 |
| `ex.fatal` / 未预期异常 | 不重排 | 记 ERROR 日志，**停止整个脚本** |
| 连续失败 ≥ 3 次 | 不重排 | 记 ERROR 日志，停止脚本（需人工介入） |

**空转策略**：没有到期任务时，`sleep` 到最近一个到期时间与 30 秒中的较小值，避免高频空转。

## 8. 状态与设置

两个存储，职责不同：

| 存储 | 位置 | 内容 | 谁写 |
|---|---|---|---|
| `state.json` | `getWorkPath()/saoif_state/state.json` | `nextRun`、`lastResult`、`successCount`、`failureStreak` | 调度器 |
| `saoif_main.config` | lrjl 自动管理 | 主界面控件值（上次选中的任务、全局选项） | lrjl 自动 |
| `tasks_<名>.config` | lrjl 自动管理 | 该任务参数页的所有控件值 | lrjl 自动 |

**为什么每任务的调度设置（启用/优先级/间隔）不放在界面配置里**：主界面是静态 XML，只有**一组**调度控件（下拉框选中的那个任务显示在这组控件上）。保存时把面板值写回 `state.json` 中该任务的记录。这样 N 个任务共用一组静态控件，无需为每个任务硬编码一行。

`state.json` 结构：

```json
{
  "tasks": {
    "fishing": {
      "enable": true, "priority": 5,
      "successInterval": 3600, "failureInterval": 3600,
      "nextRun": 1789033211, "successCount": 12, "failureStreak": 0,
      "lastResult": "success"
    }
  }
}
```

**首次运行**：`nextRun` 缺失视为「立即到期」。`getWorkPath()` 是设备路径、不进 git，换设备或重装后状态重置，行为是「所有任务各跑一次」，可接受。

**落盘时机**：每次任务结算后立即 `state.save()`（写整个文件，简单可靠）。用户在主界面改设置时也立即保存。

**模块分工**：`core/state.lua` 只管 `state.json` 的读写；`core/settings.lua` 在其之上提供「按任务名读写调度设置」的语义化接口（`get(name)` 补默认值、`update(name, patch)`），供主界面保存时调用。调度器只依赖 `settings`，不直接碰文件路径。

## 9. 配置

- **任务参数**：`界面/tasks/<名>.ui` 绑 `配置文件="tasks_<名>.config"`，lrjl 自动保存/回填。`config.lua` 负责把这些控件值读成一个 table，**默认值只在这里写一份**，XML 的 `默认值` 属性仅作为首次运行的初值。
- **不要**依赖界面配置保存运行状态文字（`setUIText` 写的标签会被一起保存），这类文字一律在 `onload` 里重新赋值。

## 10. 界面流程

```
主界面 (界面/saoif.ui)
  ├─ 下拉框 selTask        选任务（静态列出全部任务）
  ├─ 启用 chkEnable        当前选中任务的调度设置
  ├─ 优先级 edPriority
  ├─ 成功间隔 edSuccessInterval / 失败间隔 edFailureInterval
  ├─ 下次运行 lblNextRun   只读，运行时 setUIText 刷新
  ├─ 按钮 btnConfig   → 关主界面 → 开该任务参数页 → 关掉后回主界面
  ├─ 按钮 btnSelfCheck → 跑纯逻辑自检，结果 toast + 日志
  └─ 继续 / 退出      → 开始调度循环 / 结束脚本
```

用「关一个再开一个」的 `while` 循环实现跳转，意图通过闭包 upvalue 回传：

```lua
local action
local function onEvent(handle, event, arg1, arg2)
    if event == "onclick" and arg2 == "btnConfig" then
        action = "config"; closeWindow(handle, true)
    elseif event == "onclose" then
        action = arg1 and (action or "run") or "quit"
        closeWindow(handle, arg1)
    end
end
showUI("saoif.ui", 640, 860, onEvent)
-- showUI 返回后按 action 决定：开参数页 / 进主循环 / 退出
```

**硬约束**：不在 `onload` 里 `closeWindow`（实测关不掉，会叠窗）。

## 11. 识别层：规则对象

把「特征数据」与「匹配行为」分开，直接解决比色串写死在逻辑里的问题。

```lua
-- 脚本/tasks/fishing/assets.lua
local rule = require("vision.rule")

return {
    DO1    = rule.color("1182|485|00CFCF-0F0F0F,...", { tol = 15, rate = 0.6 }),
    TARGET = rule.color("499|108|F7F9FB-0F0F0F,...",  { tol = 15, rate = 0.6 }),
    CLONE  = rule.image("Fishing_clone.png", { roi = {915,173,961,217}, sim = 0.8 }),
    TAP    = rule.click(1173, 510),
}
```

```lua
-- 脚本/tasks/fishing/task.lua 里使用
local rule = require("vision.rule")
local A = require("tasks.fishing.assets")

if rule.appear(A.DO1) then
    rule.click(A.TAP)
elseif rule.appearThenClick(A.CLONE) then
    ctx.stats.hit = ctx.stats.hit + 1
elseif rule.waitAppear(A.TARGET, 6000) then
    ...
end
```

`rule` 提供的通用动作：`appear(r)`、`waitAppear(r, timeoutMs)`、`click(r)`、`appearThenClick(r)`、`dumpPoints(str, label)`（调试）。

## 12. 错误处理

Lua 没有异常类，用带 `kind` 字段的错误表：

```lua
local ex = require("core.exception")
error(ex.recoverable("卡在加载页"))   -- 重排本任务
error(ex.fatal("配置缺失"))           -- 停止脚本
```

`core/exception.lua` 只定义三种 `kind`：`recoverable` / `fatal` / `taskEnd`。`taskEnd` 用于「提前正常结束本任务」（如已达目标次数），调度器按成功结算。

调度器用 `pcall` 捕获，按 `kind` 分派（见第 7 节表格）。**未预期异常一律按 fatal 处理并停止脚本** —— 挂机场景下静默吞掉错误比停下来更危险。

## 13. 测试策略

| 层次 | 手段 | 是否需要游戏在跑 |
|---|---|---|
| 纯逻辑 | `脚本/dev/selfcheck.lua`：调度器排序/结算、state 读写往返、配置解析 | 否 |
| 单任务 | `脚本/tasks/<名>/test.lua`：在游戏内验证该任务的特征与流程 | 是 |
| 界面 | 主界面【自检】按钮触发 selfcheck，结果 toast + 日志 | 否 |
| 端到端 | 真机跑 `脚本/saoif.lua`，看 IDE 日志与截图 | 是 |

自检必须能在**不启动游戏**的情况下跑完，这是回归的第一道防线。

## 14. 迁移路径

1. 搭骨架：建目录、`core/` 六个模块、`vision/rule.lua`、占位 README。
2. 迁移钓鱼：`fishing.lua` 拆成 `tasks/fishing/{task,assets,config}.lua`；比色串进 `assets.lua`；参数页从 `saoif.ui` 迁到 `界面/tasks/fishing.ui`。
3. 主界面改造：`界面/saoif.ui` 改成「下拉框 + 调度面板」。
4. 回归：钓鱼功能与迁移前行为一致（对比日志中的成功次数与提竿时序）。
5. 清理：`spike/` 目录与临时入口删除，`saoif.lua` 恢复为正式入口。

## 15. 参考项目移植取舍

参考项目 `D:\project\AuotScript\SaoifAutoScript`（Alas/OAS 血统，62 个任务模块）。

**移植**：
- 规则资产（atom）思想 → `vision/rule.lua`
- 到期时间调度器 → `core/scheduler.lua`
- 任务 = 目录 + `run()`，扫目录/清单发现 → `tasks/<名>/`
- 每任务运行上限 `limitTime` / `limitCount` → 任务协议字段
- 异常分类 → 处理策略 → `core/exception.lua`
- 页面图 + BFS 寻路（后续实现）→ `game/page.lua`

**不移植**：
- 内嵌 Python 运行时、QML 桌面 GUI、FastAPI + zerorpc 远程服务
- pydantic 反射式配置表单（Lua 无对应物，改用静态 UI + 自动持久化）
- ADB/minitouch 设备层（lrjl 已提供）
- OCR 子进程 RPC、assets 代码生成器

**一处修正**：参考项目里的 `Fishing` 本身是原型（无 `config.py`、无 `next_run`、45 秒死循环），当前 `fishing.lua` 是它的忠实移植。本次迁移顺带把它提升为符合协议的正规任务。

## 16. 未决问题

1. **停止信号**：`setStopCallBack` 的回调触发时机与主循环 `ctx.shouldStop()` 的关系尚未实测（spike 未覆盖）。实施第一步先验证：注册回调后设标志位，在主循环里读。若该回调在任务 `run` 期间不触发，则改用其他停止检测方式（届时查 API 文档确认可用函数）。
2. **休眠期策略**：长时间无到期任务时是否关闭游戏省电（参考项目有 `close_game`/`goto_main`/`stay_there` 三档）。本期**不做**，先固定 `stay_there`。
3. **`game/page.lua` 的页面图**：本期只留占位，等公告板/每日任务真正开写时再设计——现在设计会是猜测。
