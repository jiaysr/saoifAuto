-- 脚本/dev/selfcheck.lua
-- 纯逻辑自检。lrjl 专有 API 不可用时对应用例自动跳过，
-- 因此本文件也能在电脑上用标准 Lua 跑：lua 脚本/dev/selfcheck.lua
local a  = require("dev.assert")
local ex = require("core.exception")
local task = require("core.task")
local registry = require("core.registry")

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

local st = require("core.state")
local settings = require("core.settings")

local function caseState()
    if not _M.onDevice() then
        a.skip("state 读写往返", "需要 lrjl 文件 API")
        return
    end
    -- 任务名每次运行都不同：否则上一轮写进 state.json 的记录会让"未知任务"前提失效
    -- （state 记录跨进程持久化，本用例必须可重复运行）
    local name = "selfcheck_" .. tostring(os.time())
    st.reset()
    local rec = st.get(name)
    a.eq(type(rec), "table", "state.get 对未知任务返回空表")
    a.eq(rec.nextRun, nil, "新任务的 nextRun 为空（视为立即到期）")

    rec.nextRun = 1700000000
    rec.successCount = 7
    a.ok(st.save(), "state.save 写入成功")

    st.reset()
    local again = st.get(name)
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
                                                    interval = { success = 2, failure = 3 } })
    a.eq(cfg.enabled, true, "无配置时 enabled 回落默认")
    a.eq(cfg.priority, 5, "无配置时 priority 回落默认")
    a.eq(cfg.successInterval, 2, "无配置时 successInterval 回落默认")
end

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

    -- 连续失败到阈值应停止
    a.eq(sched.shouldGiveUp(0), false, "shouldGiveUp 对 0 次失败返回 false")
    a.eq(sched.shouldGiveUp(sched.MAX_FAILURE_STREAK - 1), false, "shouldGiveUp 未达阈值返回 false")
    a.eq(sched.shouldGiveUp(sched.MAX_FAILURE_STREAK), true, "shouldGiveUp 达到阈值返回 true")
end

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

function _M.run()
    a.reset()
    print("[selfcheck] 运行环境: " .. (_M.onDevice() and "lrjl 设备" or "本机 Lua（设备相关用例将跳过）"))

    caseException()
    caseState()
    caseSettings()
    caseTask()
    caseRegistry()
    caseScheduler()
    caseRule()

    return a.report("selfcheck")
end

return _M
