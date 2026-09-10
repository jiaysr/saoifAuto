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
