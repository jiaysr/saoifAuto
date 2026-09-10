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
    rowpool.fill(allPool, handle, 1, tasks, function(t)
        local s = settings.read(t.name, t)
        local tail = s.enabled and "已启用" or "已禁用"
        return string.format("%s　（%s）", t.title, tail)
    end)
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
            -- 按前缀选定行池，再按行号取任务。用 if 而非 and/or ——
            -- `a and b or c` 在 b 为 nil 时会穿透去求值 c，从而查错行池。
            local pool = (prefix == "btnRow") and ovPool or allPool
            local entry = rowpool.taskAt(pool, idx)
            if entry then
                -- 总览页存 {task=,priority=,nextRun=}，配置页存任务本身
                local t = entry.task or entry
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

-- 读全局设置：连续失败阈值（全局标签页的 edMaxFail）。
-- 不读就等于界面上有个什么都不做的控件 —— 会误导用户以为设置了什么。
local gcfg  = settings.decode(getUIConfig and getUIConfig("saoif.config") or "")
local gpage = settings.page(gcfg, 2)          -- page2 = 全局标签页（总览0 / 配置1 / 全局2）
scheduler.MAX_FAILURE_STREAK = settings.num(gpage.edMaxFail, scheduler.MAX_FAILURE_STREAK)
logger.info(string.format("连续失败阈值 = %d", scheduler.MAX_FAILURE_STREAK))

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
