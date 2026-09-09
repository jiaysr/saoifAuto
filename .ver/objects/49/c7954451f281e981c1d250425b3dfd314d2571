-- 脚本/core/logger.lua
-- 统一日志模块：带标签与时间戳，方便在 IDE 输出面板中过滤

local _M = {}

local TAG = "SAOIF"

local function now()
    return os.date("%H:%M:%S")
end

local function fmt(msg, ...)
    if select("#", ...) > 0 then
        local ok, s = pcall(string.format, msg, ...)
        if ok then return s end
    end
    return tostring(msg)
end

function _M.info(msg, ...)
    print(string.format("[%s][I][%s] %s", TAG, now(), fmt(msg, ...)))
end

function _M.warn(msg, ...)
    print(string.format("[%s][W][%s] %s", TAG, now(), fmt(msg, ...)))
end

function _M.error(msg, ...)
    print(string.format("[%s][E][%s] %s", TAG, now(), fmt(msg, ...)))
end

function _M.debug(msg, ...)
    print(string.format("[%s][D][%s] %s", TAG, now(), fmt(msg, ...)))
end

return _M
