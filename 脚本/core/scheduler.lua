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
    local ok, kind, message

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
    if rec.failureStreak >= _M.MAX_FAILURE_STREAK then
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
