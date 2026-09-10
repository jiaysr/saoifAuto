-- 脚本/saoif.lua
-- 正式入口：装配任务清单 → 显示主界面 → 交给调度主循环
local logger    = require("core.logger")
local registry  = require("core.registry")
local scheduler = require("core.scheduler")
local state     = require("core.state")
local settings  = require("core.settings")
local ex        = require("core.exception")
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
    -- pcall 捕获的是错误值本身：协议违规是带 message 的异常表，
    -- 语法错/缺模块是裸字符串。统一用 kindOf 取出人可读的那句，
    -- 否则 tostring(err) 只会打出 "table: 0x..."，丢了真实原因。
    local _, message = ex.kindOf(tasks)
    logger.error("任务装载失败: " .. tostring(message))
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
        -- ⚠ 参数必须带 arg1！onclose 的 arg1 是「点了继续(true) 还是退出(false)」，
        --   少了它 arg1 会解析成全局 nil，窗口以 save=false 关闭 ——
        --   任务参数页的所有修改（启用/优先级/间隔/功能参数）会被静默丢弃，
        --   而且日志里完全看不出来。设备验证过的写法就是下面这样透传 arg1。
        local function onTaskEvent(handle, event, arg1)
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
-- math.floor：用户可能填 7.5，而下面的日志用 %d 格式化；
-- Lua ≥5.3 里 string.format("%d", 7.5) 会直接抛错（且发生在主循环之前）。
local maxFail = math.floor(settings.num(gpage.edMaxFail, scheduler.MAX_FAILURE_STREAK))
-- 下限保护：shouldGiveUp 是 streak >= MAX，成功后 streak 归 0，
-- 故 MAX=0 会让判据恒真、脚本在第一次成功后就停。本项目别处的习惯是
-- 「0 = 不限制」，用户很可能这么填，故必须挡住。
if maxFail < 1 then
    logger.warn(string.format("最大连续失败次数 %d 无效，回落默认 %d",
        maxFail, scheduler.MAX_FAILURE_STREAK))
    maxFail = scheduler.MAX_FAILURE_STREAK
end
scheduler.MAX_FAILURE_STREAK = maxFail
logger.info(string.format("连续失败阈值 = %d", scheduler.MAX_FAILURE_STREAK))

-- 全部任务都禁用时，主循环只会每 30 秒空转一次，没有任何提示 ——
-- 用户点了【继续】却进入静默爬行，必须明确告警。
local anyEnabled = false
for _, t in ipairs(tasks) do
    if settings.read(t.name, t).enabled then anyEnabled = true; break end
end
if not anyEnabled then
    logger.warn("没有任何启用的任务，脚本将一直空转；请在【配置】标签页启用至少一个任务后重新运行")
end

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
