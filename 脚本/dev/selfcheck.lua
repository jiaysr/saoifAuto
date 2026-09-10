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

function _M.run()
    a.reset()
    print("[selfcheck] 运行环境: " .. (_M.onDevice() and "lrjl 设备" or "本机 Lua（设备相关用例将跳过）"))

    caseException()
    caseState()
    caseSettings()

    return a.report("selfcheck")
end

return _M
