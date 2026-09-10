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

    -- 默认间隔支持两种写法：扁平的 successInterval，或 defaults.interval.success
    local iv = defaults.interval or {}
    return {
        enabled         = _M.bool(p.chkEnable, defaults.enabled ~= false),
        priority        = _M.num(p.edPriority, defaults.priority or 5),
        successInterval = _M.num(p.edSuccessInterval, defaults.successInterval or iv.success or 1),
        failureInterval = _M.num(p.edFailureInterval, defaults.failureInterval or iv.failure or 1),
    }
end

return _M
