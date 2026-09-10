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
