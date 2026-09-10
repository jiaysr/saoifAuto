# SAOIF 框架骨架 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `脚本/` 重构成可扩展的四层框架，并把钓鱼迁移为符合协议的第一个任务，使新增功能只需「建一个目录 + 一个参数页 + 清单加一行」。

**Architecture:** 到期时间调度器驱动；每个任务是一个目录，返回声明式任务表；任务设置存在各自参数页的 lrjl 配置文件中（`getUIConfig` 读取），运行时状态（`nextRun`）存 `state.json`；界面用静态 XML + 固定行池实现动态列表。

**Tech Stack:** 懒人精灵（lrjl）Lua 5.4 / Android；静态 XML 界面；无第三方测试框架，用自建 `dev/assert.lua` + 真机日志。

**Spec:** `docs/superpowers/specs/2026-09-10-saoif-framework-design.md`

## Global Constraints

- 语言：懒人精灵 Lua（Lua 5.4 语法），UTF-8 编码，注释用中文
- 目录约定（lrjl 规范）：Lua 脚本放 `脚本/`，界面 `.ui` 放 `界面/`，资源放 `资源/`，`cache/` 自动生成不得手改
- 分辨率基准：1280x720 横屏（设备 720x1280 竖屏 + rotate=1）
- 静态 UI 支持的控件只有：文本框、输入框、按钮、多选框、单选框、下拉框、浏览器。**没有表格控件，且不能运行时增删控件**
- `getUIConfig(name)` 返回 **JSON 字符串**，结构 `{"page0":{"控件id":"值"}}`，**值全是字符串**
- `<窗口 配置文件="x.config">` 自动保存/回填所有控件值，包括运行时 `setUIText` 写的文字
- **禁止在 `onload` 回调里调用 `closeWindow`** —— 实测关不掉，窗口会叠在下一个窗口上
- `showUI` 是阻塞的，关闭时返回配置 JSON；界面流转用「关一个再开一个」的循环 + 闭包 upvalue 传意图
- `core/` 不得 `require` `tasks/`（依赖单向：tasks → core/vision/game）
- 运行时状态目录：`getWorkPath() .. "/saoif_state/"`

## 测试方式说明

本项目没有也不引入测试框架。测试靠 `脚本/dev/selfcheck.lua`：一个纯逻辑断言集，打印 `通过/失败/跳过`，末尾输出汇总行。

**两种跑法：**

- **设备（默认）**：`mcp__lrjl__script_control(action="run")` → 等待 → `mcp__lrjl__get_ide_logs()`。设备须已连接。
- **本机（可选，快）**：装了 Lua 后 `lua 脚本/dev/selfcheck.lua`。`lrjl` 专有 API 不可用时，相关用例自动「跳过」而非失败。

**每个任务结束前，汇总行必须是 `0 失败`。**

---

### Task 1: 自检骨架与错误类型

建立测试工具本身，以及全框架共用的错误分类模块。

**Files:**
- Create: `脚本/dev/assert.lua`
- Create: `脚本/dev/selfcheck.lua`
- Create: `脚本/core/exception.lua`
- Modify: `脚本/saoif.lua`（临时改为自检入口，Task 8 会替换成正式入口）

**Interfaces:**
- Consumes: 无
- Produces:
  - `require("dev.assert")` → `{ ok(cond, name, detail), eq(actual, expected, name), skip(name, why), reset(), report(tag) -> allPassed }`
  - `require("core.exception")` → `{ recoverable(msg), fatal(msg), taskEnd(msg), kindOf(err) -> kind, message }`；`kindOf` 对非本模块错误一律返回 `"fatal"`

- [ ] **Step 1: 写断言工具**

创建 `脚本/dev/assert.lua`：

```lua
-- 脚本/dev/assert.lua
-- 极简断言收集器：不中断执行，跑完统一报告
local _M = {}

local results = {}

local function record(entry)
    results[#results + 1] = entry
end

function _M.ok(cond, name, detail)
    record({ ok = cond and true or false, name = name, detail = detail })
    return cond and true or false
end

function _M.eq(actual, expected, name)
    return _M.ok(actual == expected, name,
        string.format("期望 %s，实际 %s", tostring(expected), tostring(actual)))
end

function _M.skip(name, why)
    record({ skip = true, name = name, detail = why })
end

function _M.reset()
    results = {}
end

function _M.summary()
    local pass, fail, skip = 0, 0, 0
    for _, r in ipairs(results) do
        if r.skip then skip = skip + 1
        elseif r.ok then pass = pass + 1
        else fail = fail + 1 end
    end
    return pass, fail, skip
end

function _M.report(tag)
    tag = tag or "selfcheck"
    for _, r in ipairs(results) do
        local mark = r.skip and "跳过" or (r.ok and "通过" or "失败")
        local detail = r.detail and ("  <" .. tostring(r.detail) .. ">") or ""
        print(string.format("[%s] %s %s%s", tag, mark, r.name, detail))
    end
    local pass, fail, skip = _M.summary()
    print(string.format("[%s] ===== 结果: %d 通过 / %d 失败 / %d 跳过 =====",
        tag, pass, fail, skip))
    return fail == 0
end

return _M
```

- [ ] **Step 2: 写错误分类模块**

创建 `脚本/core/exception.lua`：

```lua
-- 脚本/core/exception.lua
-- 错误分类：Lua 没有异常类，用带 kind 的错误表 + error() 抛出
--   recoverable 可恢复（如卡在加载页）→ 调度器重排本任务
--   fatal       需人工   （如配置缺失）→ 停止整个脚本
--   taskEnd     提前正常结束（如已达目标次数）→ 按成功结算
local _M = {}

local KINDS = { recoverable = true, fatal = true, taskEnd = true }

local function make(kind, msg)
    return { __exception = true, kind = kind, message = tostring(msg or "") }
end

function _M.recoverable(msg) return make("recoverable", msg) end
function _M.fatal(msg)       return make("fatal", msg) end
function _M.taskEnd(msg)     return make("taskEnd", msg) end

-- 判定 pcall 捕获到的 err 属于哪一类
-- 不是本模块产生的错误（含 nil、裸字符串、其他表的错误）一律按 fatal
function _M.kindOf(err)
    if type(err) == "table" and err.__exception and KINDS[err.kind] then
        return err.kind, err.message
    end
    return "fatal", tostring(err)
end

return _M
```

- [ ] **Step 3: 写自检入口**

创建 `脚本/dev/selfcheck.lua`：

```lua
-- 脚本/dev/selfcheck.lua
-- 纯逻辑自检。lrjl 专有 API 不可用时对应用例自动跳过，
-- 因此本文件也能在电脑上用标准 Lua 跑：lua 脚本/dev/selfcheck.lua
local a  = require("dev.assert")
local ex = require("core.exception")

local _M = {}

-- 平台探测：设备上这些是全局函数，本机 Lua 里为 nil
function _M.onDevice()
    return type(getWorkPath) == "function" and type(readFile) == "function"
end

local function caseException()
    a.ok(type(ex.recoverable("x")) == "table", "exception.recoverable 返回表")
    a.ok(ex.recoverable("x").__exception == true, "错误表带 __exception 标记")
    a.eq(ex.kindOf(ex.recoverable("卡住")), "recoverable", "kindOf 识别 recoverable")
    a.eq(ex.kindOf(ex.fatal("坏了")), "fatal", "kindOf 识别 fatal")
    a.eq(ex.kindOf(ex.taskEnd("做完了")), "taskEnd", "kindOf 识别 taskEnd")
    a.eq(ex.kindOf("裸字符串错误"), "fatal", "未预期字符串按 fatal")
    a.eq(ex.kindOf(nil), "fatal", "nil 错误按 fatal")
    a.eq(ex.kindOf({}), "fatal", "无关的表按 fatal")
end

function _M.run()
    a.reset()
    print("[selfcheck] 运行环境: " .. (_M.onDevice() and "lrjl 设备" or "本机 Lua（设备相关用例将跳过）"))

    caseException()

    return a.report("selfcheck")
end

return _M
```

- [ ] **Step 4: 临时改入口为自检**

把 `脚本/saoif.lua` 整体替换为（Task 8 会替换成正式入口）：

```lua
-- 脚本/saoif.lua
-- ⚠ 开发期临时入口：只跑自检。Task 8 会替换为正式入口。
-- 原实现见 main 分支。
require("dev.selfcheck").run()
```

- [ ] **Step 5: 运行自检，确认通过**

运行：`mcp__lrjl__script_control(action="run")`，等 3 秒，`mcp__lrjl__get_ide_logs()`

预期日志：

```
[selfcheck] 运行环境: lrjl 设备
[selfcheck] 通过 exception.recoverable 返回表
...
[selfcheck] ===== 结果: 8 通过 / 0 失败 / 0 跳过 =====
```

若本机装了 Lua，也可 `lua 脚本/dev/selfcheck.lua` 得到同样的 8 通过。

- [ ] **Step 6: 提交**

```bash
git add 脚本/dev 脚本/core/exception.lua 脚本/saoif.lua
git commit -m "feat: 新增自检工具与错误分类模块"
```

---

### Task 2: 状态与设置读写

**Files:**
- Create: `脚本/core/state.lua`
- Create: `脚本/core/settings.lua`
- Modify: `脚本/dev/selfcheck.lua`（追加两个用例组）

**Interfaces:**
- Consumes: `core.exception`（本任务暂不直接用）
- Produces:
  - `require("core.state")` → `{ load(), save() -> bool, get(taskName) -> record, reset() }`；`record` 字段 `nextRun`/`successCount`/`failureStreak`/`lastResult`
  - `require("core.settings")` → `{ decode(raw) -> table, page(cfg, idx) -> table, pageOf(taskName, idx) -> table, bool(v, def) -> bool, num(v, def) -> number, read(taskName, defaults) -> { enabled, priority, successInterval, failureInterval } }`
    - `pageOf(taskName, idx)` 返回该任务配置**指定标签页**的原始键值表（值均为字符串）。Task 7 的 `config.lua` 用它读自己的参数页（page1）

- [ ] **Step 1: 追加失败用例（先写测试）**

在 `脚本/dev/selfcheck.lua` 的 `caseException()` 之后加入，并在 `_M.run()` 里 `caseException()` 之后调用 `caseState()` 与 `caseSettings()`：

```lua
local st = require("core.state")
local settings = require("core.settings")

local function caseState()
    if not _M.onDevice() then
        a.skip("state 读写往返", "需要 lrjl 文件 API")
        return
    end
    st.reset()
    local rec = st.get("fishing")
    a.eq(type(rec), "table", "state.get 对未知任务返回空表")
    a.eq(rec.nextRun, nil, "新任务的 nextRun 为空（视为立即到期）")

    rec.nextRun = 1700000000
    rec.successCount = 7
    a.ok(st.save(), "state.save 写入成功")

    st.reset()
    local again = st.get("fishing")
    a.eq(again.nextRun, 1700000000, "重新加载后 nextRun 保留")
    a.eq(again.successCount, 7, "重新加载后 successCount 保留")
end

local function caseSettings()
    -- 纯逻辑部分：类型转换（不依赖 lrjl）
    a.eq(settings.bool("true", false), true, "bool 把字符串 true 转成 true")
    a.eq(settings.bool("false", true), false, "bool 把字符串 false 转成 false")
    a.eq(settings.bool("1", false), true, "bool 把字符串 1 转成 true")
    a.eq(settings.bool("0", true), false, "bool 把字符串 0 转成 false")
    a.eq(settings.bool(nil, true), true, "bool 对 nil 返回默认值")
    a.eq(settings.num("45", 1), 45, "num 把字符串转成数字")
    a.eq(settings.num(nil, 9), 9, "num 对 nil 返回默认值")
    a.eq(settings.num("abc", 9), 9, "num 对非数字返回默认值")

    if not _M.onDevice() then
        a.skip("settings.read 读真实配置", "需要 lrjl getUIConfig")
        return
    end
    -- 从未打开过参数页的任务应回落默认值
    local cfg = settings.read("__never_opened__", { enabled = true, priority = 5,
                                                    successInterval = 2, failureInterval = 3 })
    a.eq(cfg.enabled, true, "无配置时 enabled 回落默认")
    a.eq(cfg.priority, 5, "无配置时 priority 回落默认")
    a.eq(cfg.successInterval, 2, "无配置时 successInterval 回落默认")
end
```

- [ ] **Step 2: 运行确认失败**

运行：`mcp__lrjl__script_control(action="run")` → `mcp__lrjl__get_ide_logs()`

预期：报错或失败，因为 `core.state` / `core.settings` 还不存在（`module 'core.state' not found`）。

- [ ] **Step 3: 实现 core/state.lua**

创建 `脚本/core/state.lua`：

```lua
-- 脚本/core/state.lua
-- 运行时状态持久化：只放会随运行变化的东西
--   nextRun / successCount / failureStreak / lastResult
-- 位置：getWorkPath()/saoif_state/state.json
-- 注意：任务设置（启用/优先级/间隔）不在这里，见 core/settings.lua
local _M = {}

local DIR  = "saoif_state"
local FILE = "state.json"

local _data = nil
local _path = nil

local function dirPath()
    return getWorkPath() .. "/" .. DIR
end

function _M.load()
    _path = dirPath() .. "/" .. FILE
    local dir = dirPath()
    if not fileExist(dir) then mkdir(dir) end

    _data = { tasks = {} }
    if fileExist(_path) then
        local raw = readFile(_path)
        local ok, decoded = pcall(jsonLib.decode, raw or "")
        if ok and type(decoded) == "table" then
            _data = decoded
        end
    end
    _data.tasks = _data.tasks or {}
    return _data
end

function _M.save()
    if not _data then return false end
    local ok, enc = pcall(jsonLib.encode, _data)
    if not ok then return false end
    return writeFile(_path, enc) == true
end

-- 取某任务的记录；不存在则创建空记录（nextRun 为 nil，调用方视为立即到期）
function _M.get(taskName)
    if not _data then _M.load() end
    local rec = _data.tasks[taskName]
    if not rec then
        rec = {}
        _data.tasks[taskName] = rec
    end
    return rec
end

function _M.reset()
    _data = { tasks = {} }
    _path = nil
end

return _M
```

- [ ] **Step 4: 实现 core/settings.lua**

创建 `脚本/core/settings.lua`：

```lua
-- 脚本/core/settings.lua
-- 读任务参数页的配置（tasks_<名>.config），做类型转换与默认值填充。
-- 实测：getUIConfig 返回 JSON 字符串，值全是字符串（"false" 不是 false、"0" 不是 0），
-- 所有转换集中在本模块，不要散落到任务代码里。
local _M = {}

-- 把字符串/布尔/数字统一成布尔；无法识别时返回 def
function _M.bool(v, def)
    if v == true  or v == "true"  or v == "1" or v == 1 then return true  end
    if v == false or v == "false" or v == "0" or v == 0 then return false end
    return def
end

function _M.num(v, def)
    local n = tonumber(v)
    if n == nil then return def end
    return n
end

-- getUIConfig 的原始 JSON 字符串 → 表 { page0 = {...}, page1 = {...} }
function _M.decode(raw)
    if type(raw) ~= "string" or raw == "" then return {} end
    local ok, t = pcall(jsonLib.decode, raw)
    if not ok or type(t) ~= "table" then return {} end
    return t
end

function _M.page(cfg, idx)
    return cfg["page" .. tostring(idx or 0)] or {}
end

-- 取某任务配置指定标签页的原始键值表（值均为字符串）
-- 任务自己的参数页用这个读（fishing 的参数在 page1）
function _M.pageOf(taskName, idx)
    if type(getUIConfig) ~= "function" then return {} end
    return _M.page(_M.decode(getUIConfig("tasks_" .. taskName .. ".config")), idx)
end

-- 读某任务的调度设置。defaults 传任务模块本身（含 enabled/priority/interval）
function _M.read(taskName, defaults)
    defaults = defaults or {}

    local p = _M.pageOf(taskName, 0)

    local iv = defaults.interval or {}
    return {
        enabled         = _M.bool(p.chkEnable, defaults.enabled ~= false),
        priority        = _M.num(p.edPriority, defaults.priority or 5),
        successInterval = _M.num(p.edSuccessInterval, iv.success or 1),
        failureInterval = _M.num(p.edFailureInterval, iv.failure or 1),
    }
end

return _M
```

- [ ] **Step 5: 运行确认通过**

运行：`mcp__lrjl__script_control(action="run")` → `mcp__lrjl__get_ide_logs()`

预期：`===== 结果: 24 通过 / 0 失败 / 0 跳过 =====`（T1 的 8 条 + 本任务的 16 条；关键是 **0 失败**）

- [ ] **Step 6: 提交**

```bash
git add 脚本/core/state.lua 脚本/core/settings.lua 脚本/dev/selfcheck.lua
git commit -m "feat: 新增运行时状态与任务设置读写模块"
```

---

### Task 3: 任务协议与注册表

**Files:**
- Create: `脚本/core/task.lua`
- Create: `脚本/core/registry.lua`
- Create: `脚本/tasks/index.lua`
- Modify: `脚本/dev/selfcheck.lua`（追加 `caseTask`、`caseRegistry`）

**Interfaces:**
- Consumes: `core.exception`
- Produces:
  - `require("core.task")` → `{ normalize(mod) -> task, validate(mod) -> ok, err }`；`normalize` 补齐默认值（`enabled=true`、`priority=5`、`interval={success=1,failure=1}`、`limitTime=0`、`limitCount=0`）并 `validate`
  - `require("core.registry")` → `{ load(list) -> tasks, all() -> tasks, find(name) -> task }`；`load` 接收 `tasks/index.lua` 的字符串数组，逐个 `require` 并 `normalize`
  - `require("tasks.index")` → `{ "tasks.fishing.task", ... }` 字符串数组

- [ ] **Step 1: 追加失败用例**

在 `脚本/dev/selfcheck.lua` 顶部加入 `local task = require("core.task")`、`local registry = require("core.registry")`，并加：

```lua
local function caseTask()
    local ok = task.validate({})   -- 缺 name 与 run
    a.eq(ok, false, "缺 name/run 的任务校验失败")

    local ok2, err2 = task.validate({ name = "x" })
    a.eq(ok2, false, "缺 run 的任务校验失败")
    a.ok(type(err2) == "string" and #err2 > 0, "校验失败返回原因文字")

    local t = task.normalize({ name = "x", run = function() end })
    a.eq(t.enabled, true, "normalize 补 enabled 默认 true")
    a.eq(t.priority, 5, "normalize 补 priority 默认 5")
    a.eq(t.interval.success, 1, "normalize 补 interval.success 默认 1")
    a.eq(t.interval.failure, 1, "normalize 补 interval.failure 默认 1")
    a.eq(t.limitTime, 0, "normalize 补 limitTime 默认 0")
    a.eq(t.limitCount, 0, "normalize 补 limitCount 默认 0")

    local t2 = task.normalize({ name = "y", run = function() end, priority = 2,
                                interval = { success = 4 } })
    a.eq(t2.priority, 2, "normalize 不覆盖已有 priority")
    a.eq(t2.interval.success, 4, "normalize 不覆盖已有 interval.success")
    a.eq(t2.interval.failure, 1, "normalize 补齐缺失的 interval.failure")
end

local function caseRegistry()
    local fake = {
        { name = "a", run = function() end },
        { name = "b", run = function() end, priority = 1 },
    }
    registry.loadTable(fake)
    a.eq(#registry.all(), 2, "registry.loadTable 装入 2 个任务")
    a.ok(registry.find("a") ~= nil, "registry.find 按名查找")
    a.eq(registry.find("nope"), nil, "registry.find 找不到返回 nil")
end
```

- [ ] **Step 2: 运行确认失败**

预期：`module 'core.task' not found`。

- [ ] **Step 3: 实现 core/task.lua**

创建 `脚本/core/task.lua`：

```lua
-- 脚本/core/task.lua
-- 任务协议：校验 + 默认值填充。
-- 任务模块返回一张表（见设计文档 §6），本模块保证下游拿到的字段一定齐全。
local _M = {}

-- 校验任务表是否满足协议；返回 ok, 原因
function _M.validate(mod)
    if type(mod) ~= "table" then
        return false, "任务模块必须返回 table"
    end
    if type(mod.name) ~= "string" or mod.name == "" then
        return false, "任务缺少 name（字符串，唯一键）"
    end
    if type(mod.run) ~= "function" then
        return false, "任务 " .. mod.name .. " 缺少 run 函数"
    end
    if mod.readConfig ~= nil and type(mod.readConfig) ~= "function" then
        return false, "任务 " .. mod.name .. " 的 readConfig 必须是函数"
    end
    return true
end

-- 补默认值 + 校验；校验不过直接 error（fatal），避免坏任务进入调度
function _M.normalize(mod)
    local ok, err = _M.validate(mod)
    if not ok then
        error(require("core.exception").fatal("任务协议校验失败: " .. tostring(err)))
    end

    mod.title      = mod.title or mod.name
    mod.enabled    = (mod.enabled ~= false)
    mod.priority   = mod.priority or 5
    mod.limitTime  = mod.limitTime or 0
    mod.limitCount = mod.limitCount or 0

    local iv = mod.interval or {}
    mod.interval = {
        success = iv.success or 1,   -- 单位：小时
        failure = iv.failure or 1,
    }
    mod.ui = mod.ui or ("tasks/" .. mod.name .. ".ui")

    return mod
end

return _M
```

- [ ] **Step 4: 实现 core/registry.lua**

创建 `脚本/core/registry.lua`：

```lua
-- 脚本/core/registry.lua
-- 任务注册表：require 清单里的模块并建立 name -> 任务 的查找（取代 core/dispatcher.lua）
local taskModule = require("core.task")

local _M = {}

local _tasks = {}
local _byName = {}

-- 直接装入任务表数组（测试与内部使用）
function _M.loadTable(list)
    _tasks = {}
    _byName = {}
    for _, mod in ipairs(list) do
        local t = taskModule.normalize(mod)
        _tasks[#_tasks + 1] = t
        _byName[t.name] = t
    end
    return _tasks
end

-- 按 tasks/index.lua 的模块路径数组加载
function _M.load(paths)
    local mods = {}
    for _, path in ipairs(paths) do
        mods[#mods + 1] = require(path)
    end
    return _M.loadTable(mods)
end

function _M.all() return _tasks end

function _M.find(name) return _byName[name] end

return _M
```

- [ ] **Step 5: 实现任务清单（本任务下故意为空列表）**

创建 `脚本/tasks/index.lua`（Task 7 会加入真实钓鱼任务）：

```lua
-- 脚本/tasks/index.lua
-- 任务清单：纯数据。新增一个功能只需在下面加一行 + 建对应目录与参数页。
return {
    -- "tasks.fishing.task",
}
```

- [ ] **Step 6: 运行确认通过**

运行：`mcp__lrjl__script_control(action="run")` → `mcp__lrjl__get_ide_logs()`

预期：`0 失败`

- [ ] **Step 7: 提交**

```bash
git add 脚本/core/task.lua 脚本/core/registry.lua 脚本/tasks/index.lua 脚本/dev/selfcheck.lua
git commit -m "feat: 新增任务协议与注册表"
```

---

### Task 4: 到期调度器

框架的核心。`pick` 与 `settle` 设计成**纯函数**（时间与数据都从参数传入），因此可以完整测试而不碰设备和文件。

**Files:**
- Create: `脚本/core/scheduler.lua`
- Modify: `脚本/dev/selfcheck.lua`（追加 `caseScheduler`）

**Interfaces:**
- Consumes: `core.state`、`core.settings`、`core.exception`、`core.logger`
- Produces:
  - `pick(now, entries) -> entry|nil`：纯函数。`entries` 元素含 `{name, enabled, priority, nextRun}`
  - `settle(now, cfg, kind) -> { nextRun, resetStreak, result, stop }`：纯函数。`cfg` 含 `successInterval`/`failureInterval`（小时）；`kind` 取 `"success"`/`"taskEnd"`/`"recoverable"`/`"fatal"` 或 `nil`（视为 fatal）
  - `setup(tasks)`、`shouldStop()`、`requestStop()`、`nextDue(now)`、`runOnce(entry, now)`、`idleSleepMs(now)`
  - 常量：`MAX_FAILURE_STREAK = 3`、`IDLE_MAX_MS = 30000`
  - `nextDue` 返回的是 `entries()` 产出的条目（含 `.task`、`.enabled`、`.priority`、`.nextRun`、`.successInterval`、`.failureInterval`），`runOnce` 消费同一条目
  - `runOnce` 传给任务的 `ctx` 为 `{ taskName = <string>, shouldStop = <function> }`。**只承诺这两个字段**；任务自己的 HUD 与计数由任务用 `ui.hud` 与局部变量自理（见 Task 7）
  - `setup(tasks)` **不接收 settings** —— 调度器直接 `require("core.settings")`

- [ ] **Step 1: 追加失败用例**

```lua
local sched = require("core.scheduler")
local HOUR = 3600

local function caseScheduler()
    -- pick：未到期不选
    local e = sched.pick(1000, { { name = "a", enabled = true, priority = 5, nextRun = 2000 } })
    a.eq(e, nil, "pick 不选未到期的任务")

    -- pick：禁用不选
    local e2 = sched.pick(3000, { { name = "a", enabled = false, priority = 5, nextRun = 1000 } })
    a.eq(e2, nil, "pick 不选已禁用的任务")

    -- pick：nextRun 缺失视为立即到期
    local e3 = sched.pick(1000, { { name = "a", enabled = true, priority = 5 } })
    a.ok(e3 ~= nil and e3.name == "a", "pick 把缺失 nextRun 视为立即到期")

    -- pick：选最早到期
    local e4 = sched.pick(5000, {
        { name = "a", enabled = true, priority = 5, nextRun = 4000 },
        { name = "b", enabled = true, priority = 5, nextRun = 3000 },
        { name = "c", enabled = true, priority = 5, nextRun = 9000 },
    })
    a.eq(e4.name, "b", "pick 选 nextRun 最小的")

    -- pick：同时到期时优先级小的胜
    local e5 = sched.pick(5000, {
        { name = "a", enabled = true, priority = 7, nextRun = 3000 },
        { name = "b", enabled = true, priority = 2, nextRun = 3000 },
    })
    a.eq(e5.name, "b", "pick 同到期时间时选 priority 小的")

    -- settle：成功
    local s1 = sched.settle(1000, { successInterval = 2, failureInterval = 3 }, "success")
    a.eq(s1.nextRun, 1000 + 2 * HOUR, "settle 成功用 successInterval")
    a.eq(s1.resetStreak, true, "settle 成功重置连续失败计数")
    a.eq(s1.stop, false, "settle 成功不停止脚本")

    -- settle：taskEnd 按成功结算
    local s2 = sched.settle(1000, { successInterval = 2, failureInterval = 3 }, "taskEnd")
    a.eq(s2.result, "success", "settle 把 taskEnd 按成功结算")

    -- settle：可恢复失败
    local s3 = sched.settle(1000, { successInterval = 2, failureInterval = 3 }, "recoverable")
    a.eq(s3.nextRun, 1000 + 3 * HOUR, "settle 可恢复失败用 failureInterval")
    a.eq(s3.resetStreak, false, "settle 可恢复失败不重置计数")
    a.eq(s3.stop, false, "settle 可恢复失败不停止脚本")

    -- settle：致命错误停止
    local s4 = sched.settle(1000, { successInterval = 2, failureInterval = 3 }, "fatal")
    a.eq(s4.nextRun, nil, "settle 致命错误不重排")
    a.eq(s4.stop, true, "settle 致命错误停止脚本")

    -- settle：未预期异常按致命
    local s5 = sched.settle(1000, { successInterval = 2, failureInterval = 3 }, nil)
    a.eq(s5.stop, true, "settle 把未预期结果按致命处理")

    -- 连续失败到阈值应停止（纯函数，真正覆盖生产决策）
    a.eq(sched.shouldGiveUp(0), false, "shouldGiveUp 对 0 次失败返回 false")
    a.eq(sched.shouldGiveUp(sched.MAX_FAILURE_STREAK - 1), false, "shouldGiveUp 未达阈值返回 false")
    a.eq(sched.shouldGiveUp(sched.MAX_FAILURE_STREAK), true, "shouldGiveUp 达到阈值返回 true")
end
```

- [ ] **Step 2: 运行确认失败**

预期：`module 'core.scheduler' not found`。

- [ ] **Step 3: 实现 core/scheduler.lua**

创建 `脚本/core/scheduler.lua`：

```lua
-- 脚本/core/scheduler.lua
-- 到期时间调度器：挑最早到期的启用任务执行，跑完按结果重算 nextRun。
-- pick / settle 是纯函数（时间与数据全从参数进），便于测试。
local ex     = require("core.exception")
local state  = require("core.state")
local settings = require("core.settings")
local logger = require("core.logger")

local _M = {}

_M.MAX_FAILURE_STREAK = 3   -- 同一任务连续失败达到此值 → 停止脚本等人工
_M.IDLE_MAX_MS        = 30000

local HOUR = 3600

local _tasks = nil
local _stop  = false

function _M.setup(tasks)
    _tasks = tasks
    _stop = false
end

function _M.requestStop() _stop = true end
function _M.shouldStop()  return _stop end

-- 纯函数：从候选条目里挑最早到期的启用项（同到期时间时 priority 小的胜）
function _M.pick(now, entries)
    local best
    for _, e in ipairs(entries) do
        local due = e.nextRun or 0            -- 缺失视为立即到期
        if e.enabled and due <= now then
            if not best
               or due < (best.nextRun or 0)
               or (due == (best.nextRun or 0) and e.priority < best.priority) then
                best = e
            end
        end
    end
    return best
end

-- 纯函数：按运行结果算出下次运行时间与后续动作
function _M.settle(now, cfg, kind)
    if kind == "success" or kind == "taskEnd" then
        return { nextRun = now + cfg.successInterval * HOUR,
                 resetStreak = true, result = "success", stop = false }
    end
    if kind == "recoverable" then
        return { nextRun = now + cfg.failureInterval * HOUR,
                 resetStreak = false, result = "recoverable", stop = false }
    end
    return { nextRun = nil, resetStreak = false, result = "fatal", stop = true }
end

-- 纯函数：连续失败是否已达放弃阈值（达阈值 → 停止脚本等人工介入）
function _M.shouldGiveUp(streak)
    return (streak or 0) >= _M.MAX_FAILURE_STREAK
end

-- 组装当前候选条目（融合任务默认值、用户设置、运行时状态）
function _M.entries(tasks)
    tasks = tasks or _tasks
    local list = {}
    for _, t in ipairs(tasks) do
        local s = settings.read(t.name, t)
        list[#list + 1] = {
            name = t.name, task = t,
            enabled = s.enabled, priority = s.priority,
            successInterval = s.successInterval, failureInterval = s.failureInterval,
            nextRun = state.get(t.name).nextRun,
        }
    end
    return list
end

function _M.nextDue(now)
    return _M.pick(now, _M.entries())
end

-- 执行一次任务，内部消化异常，绝不冒泡到主循环
function _M.runOnce(entry, now)
    local t = entry.task
    logger.info(string.format("========== 开始任务: %s ==========", t.title))

    local cfg = {}
    local kind, message

    -- 注意：readConfig 不带参数。调度器执行任务时配置窗口早已关闭，
    -- 没有 handle 可用；任务应从已持久化的配置文件读取（见 core/settings.pageOf）。
    if type(t.readConfig) == "function" then
        local okCfg, c = pcall(t.readConfig)
        if okCfg and type(c) == "table" then cfg = c end
    end

    -- ctx.shouldStop 必须真的可用，否则任务里的停止检查永远不会触发
    local okRun, err = pcall(t.run, cfg, {
        taskName = t.name,
        shouldStop = _M.shouldStop,
    })
    if okRun then
        kind, message = "success", nil
    else
        kind, message = ex.kindOf(err)
    end

    local s = _M.settle(now, entry, kind)
    local rec = state.get(t.name)
    rec.nextRun = s.nextRun
    rec.lastResult = s.result
    if s.resetStreak then
        rec.failureStreak = 0
    else
        rec.failureStreak = (rec.failureStreak or 0) + 1
    end
    if s.result == "success" then
        rec.successCount = (rec.successCount or 0) + 1
    end
    state.save()

    if s.result == "success" then
        logger.info(string.format("========== %s 完成 ==========", t.title))
    elseif s.result == "recoverable" then
        logger.warn(string.format("%s 可恢复失败: %s（连续 %d 次）",
            t.title, tostring(message), rec.failureStreak))
    else
        logger.error(string.format("%s 致命错误: %s", t.title, tostring(message)))
    end

    if s.stop then return true end
    if _M.shouldGiveUp(rec.failureStreak) then
        logger.error(string.format("%s 连续失败 %d 次，停止脚本等待人工介入",
            t.title, rec.failureStreak))
        return true
    end
    return false
end

-- 没有到期任务时睡多久：到最近一个到期时间与上限之间取小
function _M.idleSleepMs(now)
    local soonest
    for _, e in ipairs(_M.entries()) do
        if e.enabled and e.nextRun then
            if not soonest or e.nextRun < soonest then soonest = e.nextRun end
        end
    end
    if not soonest then return _M.IDLE_MAX_MS end
    local ms = (soonest - now) * 1000
    if ms < 100 then ms = 100 end
    if ms > _M.IDLE_MAX_MS then ms = _M.IDLE_MAX_MS end
    return ms
end

return _M
```

- [ ] **Step 4: 运行确认通过**

运行：`mcp__lrjl__script_control(action="run")` → `mcp__lrjl__get_ide_logs()`

预期：`0 失败`，且 settle/pick 的 16 条断言全部通过。

- [ ] **Step 5: 提交**

```bash
git add 脚本/core/scheduler.lua 脚本/dev/selfcheck.lua
git commit -m "feat: 新增到期时间调度器"
```

---

### Task 5: 识别层（vision）

把比色能力从 `core/` 提升到 `vision/`，并引入规则对象，解决比色串写死在业务逻辑里的问题。

**Files:**
- Create: `脚本/vision/pixel.lua`（由 `脚本/core/pixel.lua` 移动，内容不变）
- Delete: `脚本/core/pixel.lua`
- Create: `脚本/vision/rule.lua`
- Create: `脚本/vision/image.lua`
- Modify: `脚本/dev/selfcheck.lua`（追加 `caseRule`）
- Modify: `脚本/tasks/fishing.lua`（临时把 `require("core.pixel")` 改成 `require("vision.pixel")`，Task 7 会整体拆分该文件）

**Interfaces:**
- Consumes: 无（`pixel` 只用 lrjl 的 `getScreenPixel`/`colorToRGB`）
- Produces:
  - `require("vision.pixel")` → 与现在 `core/pixel` 完全相同的接口（`parsePoints` / `matchRatio` / `dumpPoints` / `findPerfectZone` / `findNeedle`）
  - `require("vision.rule")` → `{ color(str, opt), image(file, opt), click(x, y), appear(r), waitAppear(r, ms), clickRule(r), appearThenClick(r), dumpPoints(str, label) }`
    - `color` opt：`{ tol = 15, rate = 0.6 }`
    - `image` opt：`{ roi = {x1,y1,x2,y2}, halfW = 0, halfH = 0, sim = 0.8, delta = "101010" }`
      - `roi` 是**搜索区域**（比模板大）；`halfW`/`halfH` 是**模板半宽半高**，点击中心按它偏移。
        缺省 0 表示点匹配到的左上角。**漏传会让按钮中心点击静默退化成左上角点击。**
    - `require("vision.image")` → `{ tapPoint(rule, x, y) -> px, py, findCenter(rule) -> cx, cy | nil }`
      - `tapPoint` 是纯函数，唯一按模板半尺寸算点击中心的地方；selfcheck 直接钉住它。
    - `rule` 对象带 `kind` 字段（`"color"` / `"image"` / `"click"`）

- [ ] **Step 1: 追加失败用例**

```lua
local rule = require("vision.rule")

local function caseRule()
    local c = rule.color("1|2|FFFFFF-000000", { tol = 20, rate = 0.5 })
    a.eq(c.kind, "color", "rule.color 生成 color 规则")
    a.eq(c.tol, 20, "rule.color 保留自定义 tol")
    a.eq(c.rate, 0.5, "rule.color 保留自定义 rate")

    local c2 = rule.color("1|2|FFFFFF-000000")
    a.eq(c2.tol, 15, "rule.color tol 默认 15")
    a.eq(c2.rate, 0.6, "rule.color rate 默认 0.6")

    local im = rule.image("a.png", { roi = { 1, 2, 3, 4 }, sim = 0.9 })
    a.eq(im.kind, "image", "rule.image 生成 image 规则")
    a.eq(im.file, "a.png", "rule.image 保留文件名")
    a.eq(im.sim, 0.9, "rule.image 保留自定义相似度")

    local cl = rule.click(10, 20)
    a.eq(cl.kind, "click", "rule.click 生成 click 规则")
    a.eq(cl.x, 10, "rule.click 保留 x")
    a.eq(cl.y, 20, "rule.click 保留 y")
end
```

- [ ] **Step 2: 运行确认失败**

预期：`module 'vision.rule' not found`。

- [ ] **Step 3: 移动 pixel 模块**

把 `脚本/core/pixel.lua` 的内容原样复制到 `脚本/vision/pixel.lua`（只改首行注释路径，代码不动），然后删除 `脚本/core/pixel.lua`。

同时把 `脚本/tasks/fishing.lua` 里的 `local pixel = require("core.pixel")` 改成 `require("vision.pixel")`。

- [ ] **Step 4: 实现 vision/rule.lua**

创建 `脚本/vision/rule.lua`：

```lua
-- 脚本/vision/rule.lua
-- 规则对象：把「特征数据」声明成数据，把「怎么匹配/点击」收敛到这里。
-- 业务代码里不再出现裸露的比色串与坐标。
local pixel = require("vision.pixel")
local image = require("vision.image")

local _M = {}

local DEFAULTS = {
    color = { tol = 15, rate = 0.6 },
    image = { sim = 0.8, delta = "101010" },
}

function _M.color(str, opt)
    opt = opt or {}
    return {
        kind = "color",
        str  = str,
        tol  = opt.tol  or DEFAULTS.color.tol,
        rate = opt.rate or DEFAULTS.color.rate,
    }
end

function _M.image(file, opt)
    opt = opt or {}
    return {
        kind  = "image",
        file  = file,
        roi   = opt.roi,                       -- 搜索区域（比模板大）
        halfW = opt.halfW or 0,                -- 模板半宽，用于算点击中心
        halfH = opt.halfH or 0,                -- 模板半高
        sim   = opt.sim   or DEFAULTS.image.sim,
        delta = opt.delta or DEFAULTS.image.delta,
    }
end

function _M.click(x, y)
    return { kind = "click", x = x, y = y }
end

-- ===== 通用动作 =====

function _M.appear(r)
    if r.kind == "color" then
        local m, n = pixel.matchRatio(r.str, r.tol)
        return n > 0 and m >= n * r.rate
    elseif r.kind == "image" then
        -- 与 clickRule 共用同一条找图路径，避免两处各写一遍 findPic 与守卫
        return image.findCenter(r) ~= nil
    end
    return false
end

function _M.waitAppear(r, timeoutMs)
    local deadline = tickCount() + (timeoutMs or 5000)
    repeat
        if _M.appear(r) then return true end
        sleep(30)
    until tickCount() >= deadline
    return false
end

function _M.clickRule(r)
    if r.kind == "click" then
        tap(r.x, r.y)
        return true
    elseif r.kind == "image" then
        local cx, cy = image.findCenter(r)
        if cx then
            tap(cx, cy)
            return true
        end
    end
    return false
end

function _M.appearThenClick(r)
    if _M.appear(r) then
        return _M.clickRule(r)
    end
    return false
end

function _M.dumpPoints(str, label)
    pixel.dumpPoints(str, label)
end

return _M
```

- [ ] **Step 5: 实现 vision/image.lua**

创建 `脚本/vision/image.lua`：

```lua
-- 脚本/vision/image.lua
-- 找图封装：统一 findPic 的返回约定（-1 表示未找到）
local _M = {}

-- 纯函数：由 findPic 返回的匹配左上角，按**模板半尺寸**算出点击中心。
-- 注意：不能用 ROI 的半尺寸 —— ROI 是搜索区域，比模板大（例：CLONE_ROI 46x44
-- 而模板 40x31），用 ROI 半尺寸会点偏且与匹配位置无关。
-- 未提供 halfW/halfH 时缺省 0，即点匹配到的左上角（诚实且安全的缺省）。
function _M.tapPoint(rule, x, y)
    return x + (rule.halfW or 0), y + (rule.halfH or 0)
end

-- 找图并返回点击中心 x, y；未找到返回 nil
function _M.findCenter(rule)
    if not rule.roi then return nil end
    -- findPic 返回 ret, x, y（ret 为图片索引，-1 表示未找到）
    local ret, x, y = findPic(rule.roi[1], rule.roi[2], rule.roi[3], rule.roi[4],
        rule.file, rule.delta or "101010", 0, rule.sim or 0.8)
    if ret == -1 or x == -1 or y == -1 then return nil end
    return _M.tapPoint(rule, x, y)
end

return _M
```

- [ ] **Step 6: 运行确认通过**

运行：`mcp__lrjl__script_control(action="run")` → `mcp__lrjl__get_ide_logs()`

预期：`0 失败`（`caseRule` 的 11 条断言通过）。注意 `rule.appear` 等真机动作本任务不测，由 Task 7 端到端覆盖。

- [ ] **Step 7: 提交**

```bash
git add 脚本/vision 脚本/dev/selfcheck.lua 脚本/tasks/fishing.lua
git rm 脚本/core/pixel.lua
git commit -m "refactor: 比色模块移入 vision/ 并新增规则对象"
```

---

### Task 6: 界面能力层（行池 / 窗口 / HUD）

**Files:**
- Create: `脚本/ui/rowpool.lua`
- Create: `脚本/ui/window.lua`
- Create: `脚本/ui/hud.lua`
- Modify: `脚本/dev/selfcheck.lua`（追加 `caseRowPool`）

**Interfaces:**
- Consumes: `core.logger`
- Produces:
  - `require("ui.rowpool")` → `{ new(prefix, rows) -> pool, fill(pool, handle, page, list, fmt), indexOf(id, prefix?) -> number|nil, matchAny(id, prefixes) -> index, prefix | nil, taskAt(pool, i) -> item, visibleCount(pool) -> number }`
  - `require("ui.window")` → `{ show(uifile, w, h, onEvent) -> configJson, CLOSE_SAVE = true, CLOSE_CANCEL = false }`
  - `require("ui.hud")` → `{ new(enabled, title) -> hud, hud:update(text), hud:close() }`

- [ ] **Step 1: 追加失败用例**

```lua
local rowpool = require("ui.rowpool")

local function caseRowPool()
    local p = rowpool.new("btnRow", 4)
    a.eq(rowpool.indexOf("btnRow0"), 0, "indexOf 解析出第 0 行")
    a.eq(rowpool.indexOf("btnRow3"), 3, "indexOf 解析出第 3 行")
    a.eq(rowpool.indexOf("btnAll2"), nil, "indexOf 对不匹配的 id 返回 nil")
    a.eq(rowpool.indexOf(nil), nil, "indexOf 对 nil 返回 nil")
    a.eq(p.rows, 4, "行池记录行数")
    a.eq(p.prefix, "btnRow", "行池记录前缀")

    -- matchAny 是 Task 8 入口的点击路由，必须覆盖
    a.eq(rowpool.matchAny("btnRow3", { "btnRow", "btnAll" }), 3, "matchAny 命中第一个前缀")
    local mi, mp = rowpool.matchAny("btnAll5", { "btnRow", "btnAll" })
    a.eq(mi, 5, "matchAny 命中第二个前缀时返回行号")
    a.eq(mp, "btnAll", "matchAny 命中第二个前缀时返回该前缀")
    a.eq(rowpool.matchAny("btnZzz", { "btnRow", "btnAll" }), nil, "matchAny 无匹配时返回 nil")
    a.eq(rowpool.matchAny(nil, { "btnRow" }), nil, "matchAny 对 nil 返回 nil")
end
```

- [ ] **Step 2: 运行确认失败**

预期：`module 'ui.rowpool' not found`。

- [ ] **Step 3: 实现 ui/rowpool.lua**

创建 `脚本/ui/rowpool.lua`：

```lua
-- 脚本/ui/rowpool.lua
-- 固定行池：静态 XML 无法运行时增删控件，故预放 N 个行按钮，
-- 运行时填文字、把多余行隐藏（setUIVisible 8 = 隐藏且不占位）。
-- 点击时用 indexOf 从控件 id 反查行号，再 taskAt 反查任务。
local _M = {}

-- 从控件 id 里解析行号： "btnRow3" -> 3；不匹配返回 nil
function _M.indexOf(id, prefix)
    prefix = prefix or "btnRow"
    if type(id) ~= "string" then return nil end
    local n = string.match(id, "^" .. prefix .. "(%d+)$")
    if not n then return nil end
    return tonumber(n)
end

-- 通用解析：给多个前缀，返回 行号, 前缀
function _M.matchAny(id, prefixes)
    for _, prefix in ipairs(prefixes) do
        local i = _M.indexOf(id, prefix)
        if i then return i, prefix end
    end
    return nil
end

function _M.new(prefix, rows)
    return { prefix = prefix, rows = rows, map = {} }
end

-- 填充：list 的第 i+1 项填到第 i 行；超出 list 的行清空并隐藏
-- fmt(item) 返回该行显示文字
function _M.fill(pool, handle, page, list, fmt)
    for i = 0, pool.rows - 1 do
        local id = pool.prefix .. tostring(i)
        local item = list[i + 1]
        if item then
            pool.map[i] = item
            setUIText(handle, page, id, fmt(item))
            setUIVisible(handle, page, id, 0)
        else
            pool.map[i] = nil
            setUIText(handle, page, id, "")
            setUIVisible(handle, page, id, 8)
        end
    end
end

function _M.taskAt(pool, i)
    return pool.map[i]
end

function _M.visibleCount(pool)
    local n = 0
    for _ in pairs(pool.map) do n = n + 1 end
    return n
end

return _M
```

- [ ] **Step 4: 实现 ui/window.lua**

创建 `脚本/ui/window.lua`：

```lua
-- 脚本/ui/window.lua
-- showUI 的薄封装，统一「关一个再开一个」的窗口流转惯例。
--
-- 实测约束（不要绕开）：
--   * showUI 阻塞，窗口关闭才返回，返回值为配置 JSON 字符串
--   * 禁止在 onload 里 closeWindow —— 逻辑上会返回，但窗口不会真的关掉，会叠窗
--   * 意图用闭包 upvalue 回传：回调里记下 action，showUI 返回后主流程读取
local _M = {}

_M.CLOSE_SAVE   = true
_M.CLOSE_CANCEL = false

-- onEvent(handle, event, arg1, arg2, arg3) 为用户回调；返回值为配置 JSON
function _M.show(uifile, w, h, onEvent)
    return showUI(uifile, w, h, onEvent)
end

-- 关闭窗口。save 为 true 时 lrjl 会持久化控件值到该窗口绑定的配置文件
function _M.close(handle, save)
    closeWindow(handle, save == true)
end

return _M
```

- [ ] **Step 5: 实现 ui/hud.lua**

创建 `脚本/ui/hud.lua`：

```lua
-- 脚本/ui/hud.lua
-- HUD 封装：任务只负责说「显示什么」，不管理句柄生命周期。
local _M = {}

local HUD = {}
HUD.__index = HUD

function _M.new(enabled, title)
    return setmetatable({ enabled = enabled and true or false, title = title or "", id = nil }, HUD)
end

function HUD:update(text)
    if not self.enabled then return end
    if not self.id then self.id = createHUD() end
    showHUD(self.id, self.title .. "\n" .. tostring(text),
        14, "0xffffffff", "0xCC222222", 0, 20, 180, 360, 120)
end

function HUD:close()
    if self.id then
        hideHUD(self.id)
        self.id = nil
    end
end

return _M
```

- [ ] **Step 6: 运行确认通过**

运行：`mcp__lrjl__script_control(action="run")` → `mcp__lrjl__get_ide_logs()`

预期：`0 失败`

- [ ] **Step 7: 提交**

```bash
git add 脚本/ui 脚本/dev/selfcheck.lua
git commit -m "feat: 新增界面能力层（行池 / 窗口 / HUD）"
```

---

### Task 7: 迁移钓鱼为第一个任务

**Files:**
- Create: `脚本/tasks/fishing/task.lua`
- Create: `脚本/tasks/fishing/assets.lua`
- Create: `脚本/tasks/fishing/config.lua`
- Create: `脚本/tasks/fishing/test.lua`
- Create: `界面/tasks/fishing.ui`
- Delete: `脚本/tasks/fishing.lua`
- Modify: `脚本/tasks/index.lua`
- Modify: `脚本/dev/selfcheck.lua`（追加 `caseFishing`）

**Interfaces:**
- Consumes: `vision.rule`、`vision.pixel`、`ui.hud`、`core.exception`、`core.logger`
- Produces:
  - `require("tasks.fishing.task")` → 符合协议的任务表（`name="fishing"`, `title="钓鱼"`, `ui="tasks/fishing.ui"`）
  - `require("tasks.fishing.assets")` → `{ DO1, DO2, DO3, DO4, TARGET, CLONE }`，前五项为 `rule.color`，`CLONE` 为 `rule.image`（带 `halfW=20,halfH=15`）。**没有 `TAP`** —— 点击坐标唯一来源是 `config.defaults()` 的 `clickX/clickY`，见 R3
  - `require("tasks.fishing.config")` → `{ defaults() -> table, load() -> cfg }`（`load` 从已持久化配置的 page1 读，见 R1）

- [ ] **Step 1: 追加失败用例**

```lua
local fishTask = require("tasks.fishing.task")
local fishAssets = require("tasks.fishing.assets")
local fishConfig = require("tasks.fishing.config")

local function caseFishing()
    a.eq(fishTask.name, "fishing", "钓鱼任务 name 为 fishing")
    a.eq(fishTask.title, "钓鱼", "钓鱼任务 title 为 钓鱼")
    a.eq(fishTask.ui, "tasks/fishing.ui", "钓鱼任务 ui 指向参数页")
    a.eq(type(fishTask.run), "function", "钓鱼任务实现了 run")
    a.eq(type(fishTask.readConfig), "function", "钓鱼任务实现了 readConfig")

    a.eq(fishAssets.DO1.kind, "color", "DO1 是比色规则")
    a.eq(fishAssets.TARGET.kind, "color", "TARGET 是比色规则")
    a.eq(fishAssets.CLONE.kind, "image", "CLONE 是找图规则")

    local d = fishConfig.defaults()
    a.eq(d.loopTime, 45, "默认单轮超时 45 秒")
    a.eq(d.maxCatch, 0, "默认目标次数 0（不限）")
    a.eq(d.clickX, 1173, "默认按钮 X")
    a.eq(d.clickY, 510, "默认按钮 Y")
end
```

- [ ] **Step 2: 运行确认失败**

预期：`module 'tasks.fishing.task' not found`。

- [ ] **Step 3: 抽取特征常量到 assets.lua**

创建 `脚本/tasks/fishing/assets.lua`（比色串从原 `脚本/tasks/fishing.lua` 原样搬过来，坐标不变）：

```lua
-- 脚本/tasks/fishing/assets.lua
-- 钓鱼功能的特征与坐标常量。数据与逻辑分离：这里只有数据，匹配行为在 vision/rule.lua。
-- 坐标基准：横屏 1280x720（设备 720x1280 竖屏 + rotate=1）
local rule = require("vision.rule")

-- 比色串格式："x|y|BBGGRR-偏色,..."（颜色为原 Python RRGGBB 转 BBGGRR）
local DO1 = "1182|485|00CFCF-0F0F0F,1180|496|00DDDE-0F0F0F,1179|508|3675B5-0F0F0F,"
    .. "1179|517|07F3F3-0F0F0F,1178|530|02FFFF-0F0F0F,1177|547|26487B-0F0F0F,"
    .. "1157|546|4AF7F7-0F0F0F,1155|549|57F0F0-0F0F0F,1205|548|A6B7C8-0F0F0F"

local DO2 = "1187|494|7D5C25-0F0F0F,1174|502|304459-0F0F0F,1161|508|7C5C24-0F0F0F,"
    .. "1163|520|7D6527-0F0F0F,1162|530|565C5D-0F0F0F,1163|539|786437-0F0F0F,"
    .. "1183|538|7D6A29-0F0F0F,1195|536|776F4C-0F0F0F,1206|527|112A4C-0F0F0F,"
    .. "1211|512|79511B-0F0F0F"

local DO3 = "1183|494|006D6D-0F0F0F,1182|509|162F50-0F0F0F,1181|520|017979-0F0F0F,"
    .. "1177|536|017F7F-0F0F0F,1157|535|027676-0F0F0F,1176|547|3D4A5F-0F0F0F,"
    .. "1181|553|162741-0F0F0F,1186|548|1E2F49-0F0F0F,1199|542|172B4C-0F0F0F"

local DO4 = "1186|494|F8B446-0F0F0F,1168|515|FBD451-0F0F0F,1165|526|FBCE50-0F0F0F,"
    .. "1165|538|E0E0D7-0F0F0F,1178|538|FAD357-0F0F0F,1199|536|3265BA-0F0F0F,"
    .. "1202|534|DDDDDD-0F0F0F,1202|519|EBDCB1-0F0F0F,1193|501|FBC84E-0F0F0F"

local TARGET = "499|108|F7F9FB-0F0F0F,499|109|F7F9FB-0F0F0F,499|113|F7F9FB-0F0F0F,"
    .. "499|116|F7F9FB-0F0F0F,499|118|F7F9FB-0F0F0F,499|119|F7F9FB-0F0F0F,"
    .. "503|119|F7F7F9-0F0F0F,505|118|DD3434-0F0F0F,500|109|E15C5C-0F0F0F"

-- 逐通道容差 15，点匹配率 0.6（对应原 Python tol=15 / m >= n*0.6）
local COLOR_OPT = { tol = 15, rate = 0.6 }

return {
    DO1    = rule.color(DO1, COLOR_OPT),
    DO2    = rule.color(DO2, COLOR_OPT),
    DO3    = rule.color(DO3, COLOR_OPT),
    DO4    = rule.color(DO4, COLOR_OPT),
    TARGET = rule.color(TARGET, COLOR_OPT),

    -- 结算弹窗右上角 X 按钮模板（打包在 资源/saoif.rc，findPic 用裸文件名引用）
    -- 对应原 Python I_CLONE: roi=(915,173,961,217), threshold=0.8
    CLONE  = rule.image("Fishing_clone.png", {
        roi = { 915, 173, 961, 217 },   -- 搜索区域 46x44
        halfW = 20, halfH = 15,         -- 模板 40x31 的一半（原 Python CLONE_HALF_W/H）
        sim = 0.8,
    }),
}

-- 开始 / 提竿按钮不在这里：它的坐标是用户可配的，唯一来源是 config.defaults()
-- 里的 clickX / clickY（避免与参数页出现两份会漂移的默认值）。
```

- [ ] **Step 4: 抽取配置读取到 config.lua**

创建 `脚本/tasks/fishing/config.lua`：

```lua
-- 脚本/tasks/fishing/config.lua
-- 钓鱼参数：默认值与读取。默认值只在这里写一份（XML 的 默认值 属性仅作首次运行的初值）。
local settings = require("core.settings")

local _M = {}

function _M.defaults()
    return {
        loopTime    = 45,    -- 单轮超时（秒），成功会重置计时
        maxCatch    = 0,     -- 目标次数，0 = 不限
        clickX      = 1173,  -- 开始 / 提竿按钮
        clickY      = 510,
        scanX       = 1015,  -- 浮标扫描列
        zoneY1      = 123,   -- 完美区域扫描范围
        zoneY2      = 523,
        showHud     = true,
        debugColors = false,
    }
end

-- 从已持久化的配置读取（page1 = 钓鱼参数）。
-- 注意：调度器执行任务时窗口早已关闭，没有 handle 可用，所以一律读配置文件；
-- 参数页只负责写入，lrjl 在关窗保存时落盘。从未保存过的项回落 defaults()。
function _M.load()
    local d = _M.defaults()
    local p = settings.pageOf("fishing", 1)
    return {
        loopTime    = settings.num(p.edLoopTime, d.loopTime),
        maxCatch    = settings.num(p.edMaxCatch, d.maxCatch),
        clickX      = settings.num(p.edClickX, d.clickX),
        clickY      = settings.num(p.edClickY, d.clickY),
        scanX       = settings.num(p.edScanX, d.scanX),
        zoneY1      = settings.num(p.edZoneY1, d.zoneY1),
        zoneY2      = settings.num(p.edZoneY2, d.zoneY2),
        showHud     = settings.bool(p.chkShowHud, d.showHud),
        debugColors = settings.bool(p.chkDebugColors, d.debugColors),
    }
end

return _M
```

> 注意：参数页有两页 —— page0 是调度设置（§Task 8 的 UI），page1 是钓鱼自己的参数。因此这里用 `page = 1`。

- [ ] **Step 5: 迁移主逻辑到 task.lua**

创建 `脚本/tasks/fishing/task.lua`（把原 `脚本/tasks/fishing.lua` 的 `M.run` 逻辑搬过来，改用 `vision.rule` 与 `ui.hud`，删掉 `dispatcher.register`）：

```lua
-- 脚本/tasks/fishing/task.lua
-- 自动钓鱼。流程与原 脚本/tasks/fishing.lua 一致，仅改为使用框架能力。
local logger = require("core.logger")
local pixel  = require("vision.pixel")
local rule   = require("vision.rule")
local hud    = require("ui.hud")
local A      = require("tasks.fishing.assets")
local config = require("tasks.fishing.config")

local NEEDLE_TIMEOUT        = 6000
local CLONE_CONFIRM_FRAMES  = 5

local M = {
    name = "fishing",
    title = "钓鱼",
    ui = "tasks/fishing.ui",
    enabled = true,
    priority = 5,
    interval = { success = 1, failure = 1 },
}

-- 不带 handle：调度器执行时没有窗口，配置一律从已持久化的文件读
function M.readConfig()
    return config.load()
end

function M.run(cfg, ctx)
    cfg = cfg or config.load()
    local successCount = 0
    local hudView = hud.new(cfg.showHud, "钓鱼中")

    local function updateHud(state)
        hudView:update(string.format("[%s] 成功 %d", state, successCount))
    end

    logger.info("=== 开始钓鱼 ===")
    -- 这条是设备端唯一能证明 config.load() 真从 page1 读到值的证据，不要删
    logger.info(string.format("参数: 单轮超时=%ds 目标次数=%d 按钮=(%d,%d) 扫描列X=%d 区域Y=%d~%d",
        cfg.loopTime, cfg.maxCatch, cfg.clickX, cfg.clickY, cfg.scanX, cfg.zoneY1, cfg.zoneY2))

    setSnapCacheTime(0)

    if cfg.debugColors then
        logger.info("首帧颜色采样:")
        rule.dumpPoints(A.DO1.str, "DO1")
        rule.dumpPoints(A.DO2.str, "DO2")
        rule.dumpPoints(A.DO3.str, "DO3")
        rule.dumpPoints(A.DO4.str, "DO4")
        rule.dumpPoints(A.TARGET.str, "Target")
    end

    local endTime    = tickCount() + cfg.loopTime * 1000
    local cloneSkip  = 0
    local pullPhase  = false
    local obsPos, obsTick

    updateHud("待机")

    while tickCount() < endTime do
        local do1        = rule.appear(A.DO1)
        local do4        = rule.appear(A.DO4)
        local do3Matched = rule.appear(A.DO3)
        local textMatched = rule.appear(A.TARGET)

        if do1 then
            logger.info("点击开始")
            tap(cfg.clickX, cfg.clickY)
            pullPhase = false
            updateHud("抛竿")
        end

        if do4 then
            logger.info("提竿")
            tap(cfg.clickX, cfg.clickY)
            pullPhase = true
            obsPos, obsTick = nil, nil
            updateHud("提竿")
        end

        if pullPhase then
            local now = tickCount()
            local pos = pixel.findNeedle(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
            if pos then
                if obsPos and pos ~= obsPos and obsTick then
                    local dt = now - obsTick
                    if dt > 0 then
                        logger.info(string.format("浮标 y=%3d (%+d) 间隔=%2dms 速度=%6.0f px/s",
                            pos, pos - obsPos, dt, math.abs(pos - obsPos) * 1000 / dt))
                    end
                end
                obsPos, obsTick = pos, now
            else
                obsPos, obsTick = nil, nil
            end
        end

        if textMatched and not do3Matched then
            local pStart, pEnd = pixel.findPerfectZone(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
            if pStart then
                logger.info(string.format("完美区域: %d-%d", pStart, pEnd))
                updateHud("追踪浮标")
                local needleEnd = tickCount() + NEEDLE_TIMEOUT
                while tickCount() < needleEnd do
                    local pos = pixel.findNeedle(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
                    if pos and pos >= pStart + 5 and pos <= pEnd + 5 then
                        logger.info(string.format("命中! pos=%d", pos))
                        tap(cfg.clickX, cfg.clickY)
                        sleep(1000)
                        break
                    end
                    sleep(5)
                end
            end
        end

        if not textMatched and do3Matched then
            cloneSkip = cloneSkip + 1
            if cloneSkip >= CLONE_CONFIRM_FRAMES then
                cloneSkip = 0
                if rule.appearThenClick(A.CLONE) then
                    successCount = successCount + 1
                    logger.info(string.format("钓鱼成功! +1 (共 %d)", successCount))
                    updateHud("结算")
                    pullPhase = false
                    endTime = tickCount() + cfg.loopTime * 1000
                    sleep(1000)
                end
            end
        end

        if cfg.maxCatch > 0 and successCount >= cfg.maxCatch then
            logger.info(string.format("已达目标次数 %d，提前结束", cfg.maxCatch))
            break
        end

        if ctx and ctx.shouldStop and ctx.shouldStop() then
            logger.info("收到停止信号，结束钓鱼")
            break
        end

        sleep(30)
    end

    hudView:close()
    setSnapCacheTime(100)
    logger.info(string.format("========== 结束，共钓鱼 %d 次 ==========", successCount))
end

return M
```

- [ ] **Step 6: 写单任务调试入口**

创建 `脚本/tasks/fishing/test.lua`：

```lua
-- 脚本/tasks/fishing/test.lua
-- 单任务调试：在游戏里直接跑钓鱼，不经过主界面与调度器。
-- 用法：把 脚本/saoif.lua 临时改成 require("tasks.fishing.test").run()
local task = require("tasks.fishing.task")
local config = require("tasks.fishing.config")

local _M = {}

function _M.run()
    print("[fishing.test] 直接跑一轮钓鱼（参数取自已持久化的配置，缺失则用默认值）")
    task.run(config.load(), { taskName = "fishing" })
end

return _M
```

- [ ] **Step 7: 建参数页 UI**

创建 `界面/tasks/fishing.ui`（page0 = 调度设置，page1 = 钓鱼参数；从原 `界面/saoif.ui` 的「钓鱼设置」标签页搬迁）：

```xml
<窗口
	宽度="640"
	高度="900"
	显示确认按钮="true"
	显示标题栏="true"
	标题="钓鱼"
	配置文件="tasks_fishing.config">

	<标签页 标题="调度" 背景="#fff2f4f8">
		<垂直布局 宽度="-1" 高度="-1" 背景="#fff2f4f8">
			<垂直布局 宽度="-1" 高度="-2" 背景="#ffffffff" 边距="12,12,12,0" 内边距="16,12,16,14">
				<文本框 文本="【调度设置】" 字体大小="14" 字体颜色="#ff007aff" 宽度="-1" 高度="-2"/>
				<多选框 id="chkEnable" 选中="true" 文本="启用此任务" 字体大小="14" 宽度="-1" 高度="-2" 边距="0,10,0,0"/>
				<水平布局 宽度="-1" 高度="-2" 背景="#00ffffff" 边距="0,10,0,0">
					<文本框 文本="优先级" 字体大小="15" 字体颜色="#ff333333" 宽度="-2" 高度="56"/>
					<输入框 id="edPriority" 输入类型="1" 默认值="5" 宽度="120" 高度="56" 边距="12,0,0,0"/>
				</水平布局>
				<水平布局 宽度="-1" 高度="-2" 背景="#00ffffff" 边距="0,10,0,0">
					<文本框 文本="成功间隔(小时)" 字体大小="15" 字体颜色="#ff333333" 宽度="-2" 高度="56"/>
					<输入框 id="edSuccessInterval" 输入类型="1" 默认值="1" 宽度="120" 高度="56" 边距="12,0,0,0"/>
				</水平布局>
				<水平布局 宽度="-1" 高度="-2" 背景="#00ffffff" 边距="0,10,0,0">
					<文本框 文本="失败间隔(小时)" 字体大小="15" 字体颜色="#ff333333" 宽度="-2" 高度="56"/>
					<输入框 id="edFailureInterval" 输入类型="1" 默认值="1" 宽度="120" 高度="56" 边距="12,0,0,0"/>
				</水平布局>
				<文本框 id="lblNextRun" 文本="下次运行：—" 字体大小="13" 字体颜色="#ff666666" 宽度="-1" 高度="-2" 边距="0,10,0,0"/>
			</垂直布局>
		</垂直布局>
	</标签页>

	<标签页 标题="钓鱼参数" 背景="#fff2f4f8">
		<垂直布局 宽度="-1" 高度="-1" 背景="#fff2f4f8">

			<垂直布局 宽度="-1" 高度="-2" 背景="#ffffffff" 边距="12,12,12,0" 内边距="16,12,16,14">
				<文本框 文本="【运行参数】" 字体大小="14" 字体颜色="#ff007aff" 宽度="-1" 高度="-2"/>
				<水平布局 宽度="-1" 高度="-2" 背景="#00ffffff" 边距="0,10,0,0">
					<文本框 文本="单轮超时(秒)" 字体大小="15" 字体颜色="#ff333333" 宽度="150" 高度="56"/>
					<输入框 id="edLoopTime" 输入类型="1" 默认值="45" 宽度="110" 高度="56"/>
				</水平布局>
				<文本框 文本="无操作多久后结束，成功会重置计时" 字体大小="12" 字体颜色="#ff999999" 宽度="-1" 高度="-2" 边距="0,4,0,0"/>
				<水平布局 宽度="-1" 高度="-2" 背景="#00ffffff" 边距="0,10,0,0">
					<文本框 文本="目标次数" 字体大小="15" 字体颜色="#ff333333" 宽度="150" 高度="56"/>
					<输入框 id="edMaxCatch" 输入类型="1" 默认值="0" 宽度="110" 高度="56"/>
				</水平布局>
				<文本框 文本="达到后停止，0 = 不限制" 字体大小="12" 字体颜色="#ff999999" 宽度="-1" 高度="-2" 边距="0,4,0,0"/>
			</垂直布局>

			<垂直布局 宽度="-1" 高度="-2" 背景="#ffffffff" 边距="12,12,12,0" 内边距="16,12,16,14">
				<文本框 文本="【坐标配置】基准 1280x720" 字体大小="14" 字体颜色="#ff007aff" 宽度="-1" 高度="-2"/>
				<水平布局 宽度="-1" 高度="-2" 背景="#00ffffff" 边距="0,10,0,0">
					<文本框 文本="按钮 X" 字体大小="15" 字体颜色="#ff333333" 宽度="-2" 高度="56"/>
					<输入框 id="edClickX" 输入类型="1" 默认值="1173" 宽度="96" 高度="56" 边距="8,0,0,0"/>
					<文本框 文本="Y" 字体大小="15" 字体颜色="#ff333333" 宽度="-2" 高度="56" 边距="12,0,0,0"/>
					<输入框 id="edClickY" 输入类型="1" 默认值="510" 宽度="96" 高度="56" 边距="8,0,0,0"/>
				</水平布局>
				<水平布局 宽度="-1" 高度="-2" 背景="#00ffffff" 边距="0,10,0,0">
					<文本框 文本="扫描列 X" 字体大小="15" 字体颜色="#ff333333" 宽度="-2" 高度="56"/>
					<输入框 id="edScanX" 输入类型="1" 默认值="1015" 宽度="96" 高度="56" 边距="8,0,0,0"/>
				</水平布局>
				<水平布局 宽度="-1" 高度="-2" 背景="#00ffffff" 边距="0,10,0,0">
					<文本框 文本="扫描区 Y1" 字体大小="15" 字体颜色="#ff333333" 宽度="-2" 高度="56"/>
					<输入框 id="edZoneY1" 输入类型="1" 默认值="123" 宽度="96" 高度="56" 边距="8,0,0,0"/>
					<文本框 文本="Y2" 字体大小="15" 字体颜色="#ff333333" 宽度="-2" 高度="56" 边距="12,0,0,0"/>
					<输入框 id="edZoneY2" 输入类型="1" 默认值="523" 宽度="96" 高度="56" 边距="8,0,0,0"/>
				</水平布局>
			</垂直布局>

			<垂直布局 宽度="-1" 高度="-2" 背景="#ffffffff" 边距="12,12,12,0" 内边距="16,12,16,14">
				<文本框 文本="【高级选项】" 字体大小="14" 字体颜色="#ff007aff" 宽度="-1" 高度="-2"/>
				<多选框 id="chkShowHud" 选中="true" 文本="屏幕显示运行状态 HUD" 字体大小="14" 宽度="-1" 高度="-2" 边距="0,10,0,0"/>
				<多选框 id="chkDebugColors" 选中="false" 文本="启动时输出颜色采样调试信息" 字体大小="14" 宽度="-1" 高度="-2" 边距="0,10,0,0"/>
			</垂直布局>

		</垂直布局>
	</标签页>
</窗口>
```

- [ ] **Step 8: 登记任务并删除旧文件**

`脚本/tasks/index.lua` 改为：

```lua
-- 脚本/tasks/index.lua
-- 任务清单：纯数据。新增一个功能只需在下面加一行 + 建对应目录与参数页。
return {
    "tasks.fishing.task",
}
```

删除 `脚本/tasks/fishing.lua`。

- [ ] **Step 9: 运行自检**

运行：`mcp__lrjl__script_control(action="run")` → `mcp__lrjl__get_ide_logs()`

预期：`0 失败`，且钓鱼相关 12 条断言通过。此步不验证真机钓鱼行为（下一步做）。

- [ ] **Step 10: 真机回归钓鱼**

把 `脚本/saoif.lua` 临时改成 `require("tasks.fishing.test").run()`，在游戏钓鱼界面运行。

运行：`mcp__lrjl__script_control(action="run")` → `mcp__lrjl__get_ide_logs()` + `mcp__lrjl__get_ide_screenshot()`

预期：日志出现「点击开始 / 提竿 / 完美区域 / 命中 / 钓鱼成功! +1」，与迁移前的 `main` 分支行为一致。截图应能看到 HUD。

- [ ] **Step 11: 提交**

```bash
git add 脚本/tasks 界面/tasks/fishing.ui 脚本/dev/selfcheck.lua
git rm 脚本/tasks/fishing.lua
git commit -m "refactor: 钓鱼迁移为符合协议的任务目录"
```

---

### Task 8: 主界面三标签页与正式入口

**Files:**
- Modify: `界面/saoif.ui`（重写为总览 / 配置 / 全局 三标签页 + 行池）
- Modify: `脚本/saoif.lua`（正式入口）
- Create: `脚本/core/logger.lua`（增强：可选任务标签）

**Interfaces:**
- Consumes: `core.registry`、`core.scheduler`、`core.state`、`core.settings`、`ui.rowpool`、`ui.window`、`tasks.index`、`dev.selfcheck`
- Produces: 可运行的项目入口

- [ ] **Step 1: 重写主界面 UI**

把 `界面/saoif.ui` 整体替换为三标签页版本。总览与配置页各放 12 个行按钮（`btnRow0..11` / `btnAll0..11`），全局页放静态控件。

```xml
<窗口
	宽度="640"
	高度="900"
	显示确认按钮="true"
	显示标题栏="true"
	标题="SAOIF 自动助手"
	配置文件="saoif.config">

	<标签页 标题="总览" 背景="#fff2f4f8">
		<垂直布局 宽度="-1" 高度="-1" 背景="#fff2f4f8">
			<垂直布局 宽度="-1" 高度="-2" 背景="#ffffffff" 边距="12,12,12,0" 内边距="16,12,16,14">
				<文本框 文本="启用的任务（按下次运行时间排序）" 字体大小="15" 字体颜色="#ff007aff" 宽度="-1" 高度="-2"/>
				<文本框 id="lblOvSummary" 文本="—" 字体大小="12" 字体颜色="#ff999999" 宽度="-1" 高度="-2" 边距="0,4,0,0"/>
				<按钮 id="btnRow0" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnRow1" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnRow2" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnRow3" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnRow4" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnRow5" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnRow6" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnRow7" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnRow8" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnRow9" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnRow10" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnRow11" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<文本框 id="lblOvEmpty" 文本="" 字体大小="13" 字体颜色="#ff999999" 宽度="-1" 高度="-2" 边距="0,10,0,0"/>
			</垂直布局>
		</垂直布局>
	</标签页>

	<标签页 标题="配置" 背景="#fff2f4f8">
		<垂直布局 宽度="-1" 高度="-1" 背景="#fff2f4f8">
			<垂直布局 宽度="-1" 高度="-2" 背景="#ffffffff" 边距="12,12,12,0" 内边距="16,12,16,14">
				<文本框 文本="全部任务（点击进入该任务配置页）" 字体大小="15" 字体颜色="#ff007aff" 宽度="-1" 高度="-2"/>
				<文本框 id="lblCfgSummary" 文本="—" 字体大小="12" 字体颜色="#ff999999" 宽度="-1" 高度="-2" 边距="0,4,0,0"/>
				<按钮 id="btnAll0" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnAll1" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnAll2" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnAll3" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnAll4" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnAll5" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnAll6" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnAll7" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnAll8" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnAll9" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnAll10" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
				<按钮 id="btnAll11" 文本="" 字体大小="13" 宽度="-1" 高度="48" 边距="0,6,0,0"/>
			</垂直布局>
		</垂直布局>
	</标签页>

	<标签页 标题="全局" 背景="#fff2f4f8">
		<垂直布局 宽度="-1" 高度="-1" 背景="#fff2f4f8">
			<垂直布局 宽度="-1" 高度="-2" 背景="#ffffffff" 边距="12,12,12,0" 内边距="16,12,16,14">
				<文本框 文本="【运行】" 字体大小="14" 字体颜色="#ff007aff" 宽度="-1" 高度="-2"/>
				<多选框 id="chkGlobalHud" 选中="true" 文本="屏幕显示运行状态 HUD" 字体大小="14" 宽度="-1" 高度="-2" 边距="0,10,0,0"/>
				<水平布局 宽度="-1" 高度="-2" 背景="#00ffffff" 边距="0,10,0,0">
					<文本框 文本="最大连续失败次数" 字体大小="15" 字体颜色="#ff333333" 宽度="-2" 高度="56"/>
					<输入框 id="edMaxFail" 输入类型="1" 默认值="3" 宽度="120" 高度="56" 边距="12,0,0,0"/>
				</水平布局>
				<文本框 文本="超过后停止脚本，等待人工介入" 字体大小="12" 字体颜色="#ff999999" 宽度="-1" 高度="-2" 边距="0,4,0,0"/>
			</垂直布局>
			<垂直布局 宽度="-1" 高度="-2" 背景="#ffffffff" 边距="12,12,12,0" 内边距="16,12,16,14">
				<文本框 文本="【诊断】" 字体大小="14" 字体颜色="#ff007aff" 宽度="-1" 高度="-2"/>
				<按钮 id="btnSelfCheck" 文本="运行自检" 字体大小="15" 宽度="-1" 高度="64" 边距="0,10,0,0"/>
				<文本框 文本="纯逻辑检查，不需要游戏在运行；结果见日志" 字体大小="12" 字体颜色="#ff999999" 宽度="-1" 高度="-2" 边距="0,6,0,0"/>
			</垂直布局>
		</垂直布局>
	</标签页>
</窗口>
```

- [ ] **Step 2: 写正式入口**

把 `脚本/saoif.lua` 替换为：

```lua
-- 脚本/saoif.lua
-- 正式入口：装配任务清单 → 显示主界面 → 交给调度主循环
local logger    = require("core.logger")
local registry  = require("core.registry")
local scheduler = require("core.scheduler")
local state     = require("core.state")
local settings  = require("core.settings")
local selfcheck = require("dev.selfcheck")
local rowpool   = require("ui.rowpool")
local uiwin     = require("ui.window")
local taskPaths = require("tasks.index")

local ROWS = 12

-- ===== 启动自检：坏掉的框架不要去挂机 =====
logger.info("SAOIF 自动助手启动")
if not selfcheck.run() then
    logger.error("自检未通过，停止启动")
    toast("框架自检未通过，详见日志")
    return
end

-- ===== 装配任务 =====
local okLoad, tasks = pcall(registry.load, taskPaths)
if not okLoad then
    logger.error("任务装载失败: " .. tostring(tasks))
    toast("任务装载失败，详见日志")
    return
end
logger.info(string.format("已装载 %d 个任务", #tasks))

local ovPool  = rowpool.new("btnRow", ROWS)
local allPool = rowpool.new("btnAll", ROWS)
local allMap  = {}

-- ===== 界面 =====
local action

local function fillTaskRows(handle)
    -- 总览：只列启用任务，按 nextRun 升序
    local enabled = {}
    for _, t in ipairs(tasks) do
        local s = settings.read(t.name, t)
        if s.enabled then
            enabled[#enabled + 1] = {
                task = t, priority = s.priority,
                nextRun = state.get(t.name).nextRun,
            }
        end
    end
    table.sort(enabled, function(x, y)
        local a1, b1 = x.nextRun or 0, y.nextRun or 0
        if a1 ~= b1 then return a1 < b1 end
        return x.priority < y.priority
    end)

    rowpool.fill(ovPool, handle, 0, enabled, function(e)
        local when = e.nextRun and os.date("%H:%M:%S", e.nextRun) or "待定"
        return string.format("%s　下次 %s", e.task.title, when)
    end)
    setUIText(handle, 0, "lblOvSummary",
        string.format("共 %d 个任务，启用 %d 个", #tasks, #enabled))
    setUIText(handle, 0, "lblOvEmpty", #enabled == 0 and "没有启用的任务" or "")

    -- 配置：全部任务
    allMap = {}
    rowpool.fill(allPool, handle, 1, tasks, function(t)
        local s = settings.read(t.name, t)
        local tail = s.enabled and "已启用" or "已禁用"
        return string.format("%s　（%s）", t.title, tail)
    end)
    for i = 0, ROWS - 1 do
        allMap[i] = allPool.map[i]
    end
    setUIText(handle, 1, "lblCfgSummary",
        string.format("共 %d 个任务（含禁用）", #tasks))
end

local function onEvent(handle, event, arg1, arg2)
    if event == "onload" then
        fillTaskRows(handle)          -- 每次打开都重填：运行时文字会被存进配置文件，不可依赖

    elseif event == "onclick" then
        if arg2 == "btnSelfCheck" then
            local passed = selfcheck.run()
            toast(passed and "自检通过，详见日志" or "自检有失败项，详见日志")
            return
        end
        local idx, prefix = rowpool.matchAny(arg2, { "btnRow", "btnAll" })
        if idx then
            local t = (prefix == "btnRow") and ovPool.map[idx] or allMap[idx]
            t = t and (t.task or t) or nil
            if t then
                action = { kind = "open", task = t }
                uiwin.close(handle, uiwin.CLOSE_SAVE)
            end
        end

    elseif event == "onclose" then
        if not action then
            action = { kind = arg1 and "run" or "quit" }
        end
        uiwin.close(handle, arg1)
    end
end

while true do
    action = nil
    uiwin.show("saoif.ui", 640, 900, onEvent)

    if not action or action.kind == "quit" then
        logger.info("用户退出，脚本结束")
        return
    end

    if action.kind == "open" then
        local t = action.task
        logger.info("打开任务配置页: " .. t.title)
        -- 任务参数页自己处理关闭；这里只负责开与关
        local function onTaskEvent(handle, event)
            if event == "onload" then
                local rec = state.get(t.name)
                local when = rec.nextRun and os.date("%Y-%m-%d %H:%M:%S", rec.nextRun) or "待定"
                setUIText(handle, 0, "lblNextRun", "下次运行：" .. when)
            elseif event == "onclose" then
                uiwin.close(handle, arg1)
            end
        end
        uiwin.show(t.ui, 640, 900, onTaskEvent)
        -- 关掉后循环回到主界面

    elseif action.kind == "run" then
        break
    end
end

-- ===== 调度主循环 =====
logger.info("========== 进入调度主循环 ==========")
scheduler.setup(tasks)

while not scheduler.shouldStop() do
    local now = os.time()
    local entry = scheduler.nextDue(now)
    if entry then
        local shouldStop = scheduler.runOnce(entry, now)
        if shouldStop then break end
    else
        sleep(scheduler.idleSleepMs(now))
    end
end

logger.info("========== 调度主循环结束 ==========")
```

- [ ] **Step 3: 运行检查日志**

运行：`mcp__lrjl__script_control(action="run")` → `mcp__lrjl__get_ide_logs()`

预期：自检 `0 失败` → 「已装载 1 个任务」→ 出现主界面。

- [ ] **Step 4: 真机验证界面**

`mcp__lrjl__get_ide_screenshot()`

预期：三标签页「总览 / 配置 / 全局」。总览页显示「钓鱼　下次 待定」，共 1 个任务启用 1 个。

点「配置」标签页 → 显示「钓鱼　（已启用）」；点该行 → 打开钓鱼参数页；关闭 → 回到主界面。

- [ ] **Step 5: 提交**

```bash
git add 界面/saoif.ui 脚本/saoif.lua
git commit -m "feat: 主界面改为三标签页行池布局，入口接入调度主循环"
```

---

### Task 9: 占位目录与收尾

**Files:**
- Create: `脚本/game/README.md`、`脚本/game/page.lua`、`脚本/game/navigate.lua`
- Create: `脚本/component/README.md`
- Create: `脚本/vision/ocr.lua`
- Create: `脚本/tasks/daily/README.md`、`脚本/tasks/board/README.md`、`脚本/tasks/activity/README.md`
- Create: `界面/tasks/daily.ui`、`界面/tasks/board.ui`、`界面/tasks/activity.ui`
- Delete: `脚本/spike/`、`界面/spike_*.ui`、`脚本/core/dispatcher.lua`
- Modify: `脚本/core/logger.lua`（若 Task 7 未改）

**Interfaces:**
- Consumes: 无
- Produces: 目录骨架，供后续功能填充

- [ ] **Step 1: 建占位模块与说明**

`脚本/game/README.md`（各占位目录同此格式，改对应说明）：

```markdown
# game/ — 游戏内导航

放跨任务复用的游戏导航能力。

- `page.lua` — 页面图 + BFS 寻路（`ui_goto`）
- `navigate.lua` — 通用导航：回主界面、关闭弹窗、等待加载

本期为占位，等公告板 / 每日任务真正开写时再实现——现在设计会是猜测。
```

`脚本/component/README.md`：

```markdown
# component/ — 跨任务共享能力

放被多个任务复用的流程片段，例如：战斗循环、商店购买、领取奖励、切换账号。
每个能力一个文件，导出 `run(ctx, cfg)` 形式的函数。

参考项目 SaoifAutoScript 的 `tasks/Component/` 有 18 个这样的组件。
本期为占位。
```

`脚本/tasks/daily/README.md`（board / activity 同格式）：

```markdown
# 每日任务

对应 README 规划中的「每日任务」功能。

新任务落地步骤（详见设计文档 §6）：
1. 在本目录建 `task.lua`（返回任务表，含 name/title/ui/run）
2. 建 `界面/tasks/daily.ui`，**必须**含调度控件 `chkEnable` / `edPriority` /
   `edSuccessInterval` / `edFailureInterval` 与只读 `lblNextRun`
3. 在 `脚本/tasks/index.lua` 加一行 `"tasks.daily.task"`
```

- [ ] **Step 2: 建占位 Lua 与 UI**

`脚本/game/page.lua`：

```lua
-- 脚本/game/page.lua
-- 页面图 + BFS 寻路。本期占位，等公告板 / 每日任务开写时实现。
local _M = {}
return _M
```

`脚本/game/navigate.lua`：

```lua
-- 脚本/game/navigate.lua
-- 通用导航：回主界面 / 关闭弹窗 / 等待加载。本期占位。
local _M = {}
return _M
```

`脚本/vision/ocr.lua`：

```lua
-- 脚本/vision/ocr.lua
-- OCR 封装。本期占位；lrjl 自带 OCR，届时在此封装 detect/ocrText 等。
local _M = {}
return _M
```

`界面/tasks/daily.ui`（board / activity 同，改 `标题` 与 `配置文件`）：

```xml
<窗口
	宽度="640"
	高度="900"
	显示确认按钮="true"
	显示标题栏="true"
	标题="每日任务"
	配置文件="tasks_daily.config">

	<标签页 标题="调度" 背景="#fff2f4f8">
		<垂直布局 宽度="-1" 高度="-1" 背景="#fff2f4f8">
			<垂直布局 宽度="-1" 高度="-2" 背景="#ffffffff" 边距="12,12,12,0" 内边距="16,12,16,14">
				<文本框 文本="【调度设置】" 字体大小="14" 字体颜色="#ff007aff" 宽度="-1" 高度="-2"/>
				<多选框 id="chkEnable" 选中="true" 文本="启用此任务" 字体大小="14" 宽度="-1" 高度="-2" 边距="0,10,0,0"/>
				<水平布局 宽度="-1" 高度="-2" 背景="#00ffffff" 边距="0,10,0,0">
					<文本框 文本="优先级" 字体大小="15" 字体颜色="#ff333333" 宽度="-2" 高度="56"/>
					<输入框 id="edPriority" 输入类型="1" 默认值="5" 宽度="120" 高度="56" 边距="12,0,0,0"/>
				</水平布局>
				<水平布局 宽度="-1" 高度="-2" 背景="#00ffffff" 边距="0,10,0,0">
					<文本框 文本="成功间隔(小时)" 字体大小="15" 字体颜色="#ff333333" 宽度="-2" 高度="56"/>
					<输入框 id="edSuccessInterval" 输入类型="1" 默认值="24" 宽度="120" 高度="56" 边距="12,0,0,0"/>
				</水平布局>
				<水平布局 宽度="-1" 高度="-2" 背景="#00ffffff" 边距="0,10,0,0">
					<文本框 文本="失败间隔(小时)" 字体大小="15" 字体颜色="#ff333333" 宽度="-2" 高度="56"/>
					<输入框 id="edFailureInterval" 输入类型="1" 默认值="1" 宽度="120" 高度="56" 边距="12,0,0,0"/>
				</水平布局>
				<文本框 id="lblNextRun" 文本="下次运行：—" 字体大小="13" 字体颜色="#ff666666" 宽度="-1" 高度="-2" 边距="0,10,0,0"/>
			</垂直布局>
			<垂直布局 宽度="-1" 高度="-2" 背景="#ffffffff" 边距="12,12,12,0" 内边距="16,12,16,14">
				<文本框 文本="该功能尚未实现，本页仅占位。" 字体大小="13" 字体颜色="#ffff9500" 宽度="-1" 高度="-2"/>
			</垂直布局>
		</垂直布局>
	</标签页>
</窗口>
```

- [ ] **Step 3: 删除 spike 验证产物**

```bash
git rm -r 脚本/spike
git rm 界面/spike_main.ui 界面/spike_config.ui 界面/spike_overview.ui
# core/dispatcher.lua 已被 core/registry.lua 取代；Task 7 删掉唯一引用者
# （tasks/fishing.lua）后它就成了孤儿，在此清除
git rm 脚本/core/dispatcher.lua
```

- [ ] **Step 4: 最终验证**

运行：`mcp__lrjl__script_control(action="run")` → `mcp__lrjl__get_ide_logs()` + `mcp__lrjl__get_ide_screenshot()`

预期：自检 `0 失败`；主界面正常；总览/配置/全局三页均可切换；点钓鱼可进参数页并返回。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "chore: 补齐占位目录骨架并移除 spike 验证产物"
```

---

## 收尾检查（全部 Task 完成后）

- [ ] `脚本/core/` 里没有任何 `require("tasks....")`
- [ ] `脚本/tasks/index.lua` 是新增任务的唯一登记点
- [ ] `grep -r "core.pixel" 脚本/` 无结果（已全部改为 `vision.pixel`）
- [ ] `grep -r "dispatcher" 脚本/` 无结果（已被 registry 取代）
- [ ] 真机跑通：主界面 → 配置钓鱼 → 继续 → 调度循环启动 → 钓鱼任务执行
- [ ] `cache/` 与 `obf_selection.json` 仍在 git 中（按项目约定保留）
