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
