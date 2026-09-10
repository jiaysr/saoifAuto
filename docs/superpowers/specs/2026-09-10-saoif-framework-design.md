# SAOIF 脚本框架设计

- 日期：2026-09-10
- 状态：已确认，待实施
- 分支：`spike/framework-skeleton`（验证）→ 后续实施分支
- 说明：§3 的全部平台结论、§8 的设置存储、§10 的界面方案均为真机实测后的修订版

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
| 主界面 | **三标签页：总览 / 配置 / 全局** | 总览列出启用任务并按运行时间排序，配置列出全部任务，点击进入该任务参数页 |
| 状态持久化 | **需要，但分两类** | 任务设置靠 lrjl 配置文件，运行时状态（`nextRun`）落 `state.json` |
| 错误恢复 | **分类处理** | 可恢复错误重排本任务，需人工介入的错误停止脚本 |
| 平台 | 懒人精灵（lrjl）Lua，Android | 分辨率基准 1280x720 横屏 |

## 3. 平台行为验证结论（真机实测）

2026-09-10 在真机上通过 `脚本/spike/probe*.lua` 实测。**以下结论是设计的前提**，每条都有实测证据。

### 3.1 存储与配置

| 结论 | 实测证据 |
|---|---|
| `getWorkPath()` 可写 | 返回 `/data/local/tmp/lrwork/com.nx.nxprojit/script/work`；`writeFile`/`readFile`/`fileExist`/`mkdir` 均可用 |
| `jsonLib.encode`/`decode` 可用 | 状态表编码后写盘、读回、解码，字段值还原正确 |
| **`<窗口 配置文件="x.config">` 自动持久化所有控件值** | 4 类控件全部验证：输入框 `空→标记`、数字框 `45→88`、多选框 `true→false`、下拉框 `0→2` |
| **`getUIConfig(name)` 能在不开窗口时读回配置** | 返回 **JSON 字符串**（不是 table），结构 `{"page0":{"控件id":"值"}}`，**所有值都是字符串** |

### 3.2 窗口与交互

| 结论 | 实测证据 |
|---|---|
| `showUI` 阻塞并在关闭时返回配置 JSON | 返回值为各页各控件值的 JSON 字符串 |
| 事件回调可用闭包 upvalue 传用户意图 | 回调中 `action = "config"`，`showUI` 返回后读到该值 |
| **`onload` 内调 `closeWindow` 关不掉窗口** | 日志显示 `showUI` 已返回且脚本继续，但窗口仍盖在屏幕上 |
| `setUIText` 可以改**按钮**的文字 | 行池按钮的文字运行时被成功替换 |
| `setUIVisible(id, 8)` 隐藏行且不留空档 | 8 个行池只用 5 个，剩余 3 个收起后布局无空洞 |
| `onclick` 的 `arg2` 就是被点控件的 `id` | 由 `id` 前缀 + 序号反查行号与任务，4 次点击全部正确 |

### 3.3 静态 UI 的控件限制

静态 XML **没有表格/列表控件**，支持的只有：文本框、输入框、按钮、多选框、单选框、下拉框、浏览器。
且**无法在运行时增删控件**。

**关键推论**：

1. 每个任务的参数页只需绑一个自己的 `配置文件`，**不需要手写配置读写**；`getUIConfig` 让调度器不开窗口也能读到它。
2. 界面流转必须由**用户点击**驱动，不能用 `onload` 自动关窗来跳过步骤。
3. 「主界面 → 任务参数页 → 返回主界面」用**关一个再开一个的循环**实现，不能嵌套开子窗口。
4. 动态列表只能用**固定行池**实现（§10）——XML 预放 N 个行按钮，运行时填文字、把多余行隐藏。

## 4. 架构分层

```
表现层   界面/*.ui + 脚本/ui/       窗口流程、HUD、事件路由
框架层   脚本/core/                 调度、状态、配置、任务协议、日志、异常
能力层   脚本/vision/ 脚本/game/    图色识别、规则对象、页面导航、共享组件
业务层   脚本/tasks/<任务>/         每个游戏功能一个目录
```

依赖方向单向向下：`tasks` 依赖 `core`/`vision`/`ui`/`game`，反向不依赖。`core` 不依赖 `tasks`（任务清单由入口注入）。

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
    settings.lua             读各任务参数页的配置：getUIConfig + 类型转换 + 补默认值
    exception.lua            错误分类 → 处理策略
  vision/
    pixel.lua                比色（从 core/ 移入）
    rule.lua                 规则对象：color / image / click + 通用动作
    image.lua                找图封装
    ocr.lua                  【占位】OCR 封装
  ui/
    window.lua               showUI 阻塞封装 + 事件路由（upvalue 传 action）
    rowpool.lua              固定行池：填充/隐藏/点击反查（§10）
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
  saoif.ui                   主界面：总览 / 配置 / 全局 三个标签页（行池列表）
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
    name     = "fishing",              -- 唯一键：配置文件名、state.json 的键、清单引用名
    title    = "钓鱼",                  -- 界面显示名
    ui       = "tasks/fishing.ui",     -- 参数页（相对 界面/）
    enabled  = true,                   -- 默认启用（用户在参数页可改）
    priority = 5,                      -- 越小越优先（仅当到期时间相同时决胜）
    interval = { success = 1, failure = 1 },  -- 单位：小时

    limitTime  = 0,   -- 单轮软超时（秒），0 = 不限
    limitCount = 0,   -- 单轮目标次数，0 = 不限

    readConfig = function() ... end,    -- 从已持久化的配置文件读参数，返回 table（不带 handle）
    run        = function(cfg, ctx) ... end, -- 任务主逻辑
}
```

**`run` 的约定**：
- 自行循环直到达成 `limitCount` 或超出 `limitTime`，然后正常返回。
- 每轮循环须检查 `ctx.shouldStop()`（全局停止信号），为真时尽快返回。
- 用 `require("ui.hud").new(cfg.showHud, "标题")` 自建 HUD，`hud:update(文字)` / `hud:close()`。
- 需要中止时 `error(ex.recoverable("原因"))`；正常跑完直接 `return`。

**`ctx` 提供**：`shouldStop()`（读调度器停止标志）、`taskName`。**只有这两项** —— `ui.hud` 已经把 HUD 句柄生命周期包成一行，再往 `ctx` 里塞一层是多余的；本轮统计本来就是任务自己的局部变量。

**`readConfig` 不带参数**：调度器执行任务时配置窗口早已关闭，没有 handle 可用。任务从**已持久化的配置文件**读取（`core/settings.pageOf(taskName, page)`），参数页只负责写入。

**任务内全局副作用的还原**：任务里若改动了设备全局状态（如 `setSnapCacheTime`）或建了覆盖层（HUD），必须在 `run` 内用 `pcall` 把主体包起来，在成功与失败两条路径上都还原，然后**原样重抛**错误（`if not ok then error(err) end`）。调度器会吞掉异常继续跑下一个任务，漏还原会让整个会话都停在错误的状态里；重抛是为了让调度器的 `ex.kindOf(err)` 仍能正确分类。参见 `tasks/fishing/task.lua` 的写法。

**每个任务的参数页 UI 约定**（因设置存在这里，§8）——除功能自己的参数外，必须包含这组调度控件：

| 控件 id | 类型 | 含义 |
|---|---|---|
| `chkEnable` | 多选框 | 是否启用 |
| `edPriority` | 输入框(数字) | 优先级，越小越先跑 |
| `edSuccessInterval` | 输入框(数字) | 成功后的间隔（小时） |
| `edFailureInterval` | 输入框(数字) | 失败后的间隔（小时） |
| `lblNextRun` | 文本框（只读） | 下次运行时间，运行时刷新 |

## 7. 调度器

`core/scheduler.lua` 主循环：

```lua
local scheduler = require("core.scheduler")
scheduler.setup(tasks)                 -- 注入清单（tasks/index.lua）；设置由 core/settings 直接读

while not scheduler.shouldStop() do
    local task = scheduler.nextDue(os.time())
    if task then
        scheduler.runOnce(task)        -- 内部 pcall，异常不冒泡到主循环
    else
        sleep(scheduler.idleSleepMs()) -- 睡到最近一个到期时间，或上限
    end
end
```

**到期挑选**：遍历启用任务（启用状态来自 §8 的 `settings`），取 `nextRun <= now` 中 `nextRun` 最小者；`nextRun` 相同则 `priority` 小者胜。

**跑完结算**（`onFinish`）：

| 结果 | nextRun | 其他 |
|---|---|---|
| 正常返回 | `now + successInterval` | `failureStreak = 0`，`successCount += 1` |
| `ex.recoverable` | `now + failureInterval` | `failureStreak += 1`，记 WARN 日志 |
| `ex.fatal` / 未预期异常 | 不重排 | 记 ERROR 日志，**停止整个脚本** |
| 连续失败 ≥ 3 次 | `now + failureInterval`（沿用最后一次可恢复失败的结算） | 记 ERROR 日志，停止脚本（需人工介入） |

**空转策略**：没有到期任务时，`sleep` 到最近一个到期时间与 30 秒中的较小值，避免高频空转。

## 8. 状态与设置

两类数据分开存。**任务设置不进 `state.json`** —— 它跟着任务自己的参数页走。

| 数据 | 存哪 | 怎么读 | 怎么写 |
|---|---|---|---|
| **任务设置**：启用、优先级、成功/失败间隔，以及该任务的功能参数 | `tasks_<名>.config`（该任务参数页绑的配置文件） | `getUIConfig("tasks_<名>.config")` | lrjl 在窗口关闭时自动保存 |
| **全局设置**：最大连续失败次数 | `saoif.config`（主界面绑的配置文件） | `getUIConfig("saoif.config")` | 同上 |
| **运行时状态**：`nextRun`、`successCount`、`failureStreak`、`lastResult` | `getWorkPath()/saoif_state/state.json` | `readFile` + `jsonLib.decode` | 调度器每轮结算后 `jsonLib.encode` + `writeFile` |

**`getUIConfig` 的返回格式**（实测）：

```lua
local raw = getUIConfig("tasks_fishing.config")
-- raw 是 JSON 字符串，不是 table；按标签页索引分组：
-- {"page0":{"chkEnable":"true","edPriority":"5","edSuccessInterval":"1"}}
local cfg = jsonLib.decode(raw)
local enabled = (cfg.page0.chkEnable == "true")   -- 值全是字符串，必须自己转类型
```

**为什么这样分**：每个任务的调度设置就放在它自己的参数页上，用户在一个地方配完；lrjl 负责持久化，`getUIConfig` 让调度器不开窗口也能读到。`core/settings.lua` 封装「读某任务的 `.config` → `jsonLib.decode` → 类型转换 → 补默认值」这套样板，调度器只调它，不碰文件名与字符串转换。

`state.json` 只放**会随运行变化**的东西：

```json
{
  "tasks": {
    "fishing": {
      "nextRun": 1789033211, "successCount": 12,
      "failureStreak": 0, "lastResult": "success"
    }
  }
}
```

**首次运行**：`nextRun` 缺失视为「立即到期」（所有任务各跑一次）。`getWorkPath()` 是设备路径、不进 git，换设备或重装后运行时状态会重置；任务设置由 lrjl 的配置文件管理，与运行时状态互不影响。

**落盘时机**：每次任务结算后立即 `state.save()`（写整个文件，简单可靠）。

## 9. 配置

- **任务参数**：`界面/tasks/<名>.ui` 绑 `配置文件="tasks_<名>.config"`，lrjl 自动保存/回填。`config.lua` 负责把控件值读成 table，**默认值只在这里写一份**，XML 的 `默认值` 属性仅作为首次运行的初值。
- **类型转换**：`getUIConfig` 读回来的值**全是字符串**，`"false"` 不是 `false`、`"0"` 不是 `0`。转换集中在 `core/settings.lua`，不要散落在任务代码里。
- **不要**依赖界面配置保存运行状态文字：实测运行时用 `setUIText` 写的文字会被一并存进配置文件。这类文字（如列表行、下次运行时间）一律在 `onload` 里重新赋值。

## 10. 界面流程

主窗口 `界面/saoif.ui`，三个标签页，绑 `配置文件="saoif.config"`：

```
【总览】启用的任务，按 nextRun 升序
   行池 btnRow0 .. btnRowN（静态 XML 预放，运行时填充）
   每行文字：`任务名　下次 HH:MM:SS`
   点击某行 → 记下该行对应的任务 → 关主窗口 → 打开该任务参数页
   全部禁用时显示 lblOvEmpty

【配置】全部任务（含禁用）
   行池 btnAll0 .. btnAllN
   每行文字：`任务名　下次 …` 或 `任务名　（已禁用）`
   点击某行 → 同上

【全局】静态控件，无列表
   最大连续失败次数（edMaxFail）
   按钮 btnSelfCheck → 跑纯逻辑自检，结果 toast + 日志

底部：【继续】进入调度主循环　【退出】结束脚本
```

**行池技术**（静态 XML 无法运行时增删控件，故用固定行池）：

```lua
-- XML 里预放 ROWS 个按钮；运行时按排序结果填充，多余的隐藏
for i = 0, ROWS - 1 do
    local id = prefix .. i           -- btnRow0, btnRow1, ...
    local t = list[i + 1]
    if t then
        rowMap[i] = t
        setUIText(handle, page, id, t.title .. "　下次 " .. os.date("%H:%M:%S", t.nextRun))
        setUIVisible(handle, page, id, 0)      -- 0 = 显示
    else
        rowMap[i] = nil
        setUIText(handle, page, id, "")
        setUIVisible(handle, page, id, 8)      -- 8 = 隐藏且不占位
    end
end

-- 点击时从控件 id 反查行号，再反查任务
local idx = tonumber(string.match(tostring(arg2), "^btnRow(%d+)$"))
local task = rowMap[idx]
```

**跳转**：用「关一个再开一个」的循环，意图通过闭包 upvalue 回传（§3 推论 3）。

```lua
local action
local function onEvent(handle, event, arg1, arg2)
    if event == "onload" then
        fillRows(handle)                 -- 每次打开都重填，不依赖存下来的旧文字
    elseif event == "onclick" then
        local t = rowMap[rowIndexOf(arg2)]
        if t then action = { kind = "open", task = t }; closeWindow(handle, true) end
    elseif event == "onclose" then
        action = action or { kind = arg1 and "run" or "quit" }
        closeWindow(handle, arg1)
    end
end
showUI("saoif.ui", 640, 900, onEvent)
-- 返回后：open → 打开该任务参数页，关掉后回到主窗口；run → 进主循环；quit → 结束
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
    CLONE  = rule.image("Fishing_clone.png", {
        roi = { 915, 173, 961, 217 },   -- 搜索区域 46x44
        halfW = 20, halfH = 15,         -- 模板 40x31 的一半，点击中心按它偏移
        sim = 0.8,
    }),
}
```

> 点击坐标**不**放进 assets：它是用户可配项，唯一来源是 `config.defaults()` 的
> `clickX`/`clickY`，避免出现两份会漂移的默认值（R3）。
> `halfW`/`halfH` 必须是模板半尺寸而非 ROI 半尺寸 —— ROI 是搜索区域、比模板大，
> 用 ROI 会点偏且与匹配位置无关（R15）。

```lua
-- 脚本/tasks/fishing/task.lua 里使用
local rule = require("vision.rule")
local A = require("tasks.fishing.assets")

if rule.appear(A.DO1) then
    tap(cfg.clickX, cfg.clickY)          -- 按钮坐标来自配置，不在 assets 里
elseif rule.appearThenClick(A.CLONE) then
    hit = hit + 1                        -- 本轮计数是任务自己的局部变量（§6）
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
| 纯逻辑 | `脚本/dev/selfcheck.lua`：调度器排序/结算、state 读写往返、settings 类型转换 | 否 |
| 单任务 | `脚本/tasks/<名>/test.lua`：在游戏内验证该任务的特征与流程 | 是 |
| 界面 | 主界面【全局】页的【自检】按钮触发 selfcheck，结果 toast + 日志 | 否 |
| 端到端 | 真机跑 `脚本/saoif.lua`，看 IDE 日志与截图 | 是 |

自检必须能在**不启动游戏**的情况下跑完，这是回归的第一道防线。

## 14. 迁移路径

1. 搭骨架：建目录、`core/` 七个模块、`vision/rule.lua`、`ui/rowpool.lua`、占位 README。
2. 迁移钓鱼：`fishing.lua` 拆成 `tasks/fishing/{task,assets,config}.lua`；比色串进 `assets.lua`；参数页从 `saoif.ui` 的「钓鱼设置」标签页迁到 `界面/tasks/fishing.ui`，并补上 §6 要求的调度控件。
3. 主界面改造：`界面/saoif.ui` 改成「总览 / 配置 / 全局」三标签页 + 行池列表。
4. 回归：钓鱼功能与迁移前行为一致（对比日志中的成功次数与提竿时序）。
5. 清理：`spike/` 目录与临时入口删除，`saoif.lua` 恢复为正式入口。

**注意**：现有钓鱼参数存在 `saoif.config` 的 `page1`，迁移后改读 `tasks_fishing.config`，用户原有的参数值会回到默认。可在迁移时读一次 `saoif.config` 做一次性导入，或接受重置。

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
2. **行池上限**：固定行池意味着任务数超过 N 时，多出的任务在总览/配置页**显示不全**；且窗口高度必须按 N 定，任务少时底部留白。需确定 N（建议 12）与是否加「翻页」。**待定**。
3. **返回后落在哪个标签页**：实测未找到「程序化设置当前标签页」的 API。从任务参数页返回主窗口时，很可能总是落回第一个标签页（总览），而不是用户原来所在的标签页。若体验不可接受，需另找 API 或调整布局。**待定**。
4. **休眠期策略**：长时间无到期任务时是否关闭游戏省电（参考项目有 `close_game`/`goto_main`/`stay_there` 三档）。本期**不做**，先固定 `stay_there`。
5. **`game/page.lua` 的页面图**：本期只留占位，等公告板/每日任务真正开写时再设计——现在设计会是猜测。
