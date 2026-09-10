-- 脚本/core/state.lua
-- 运行时状态持久化：只放会随运行变化的东西
--   nextRun / successCount / failureStreak / lastResult
-- 位置：getWorkPath()/saoif_state/state.json
-- 注意：任务设置（启用/优先级/间隔）不在这里，见 core/settings.lua
local _M = {}

-- 延迟且防御性取 logger：state 在自检等场景下可能被单独加载，
-- 日志模块缺失/加载失败都不能让 save 本身抛错。
local function warnSafe(msg)
    local ok, logger = pcall(require, "core.logger")
    if ok and logger and type(logger.warn) == "function" then
        pcall(logger.warn, msg)
    end
end

local DIR  = "saoif_state"
local FILE = "state.json"

local _data = nil
local _path = nil

local function dirPath()
    return getWorkPath() .. "/" .. DIR
end

function _M.load()
    _path = dirPath() .. "/" .. FILE
    local dir = dirPath()
    if not fileExist(dir) then mkdir(dir) end

    _data = { tasks = {} }
    if fileExist(_path) then
        local raw = readFile(_path)
        local ok, decoded = pcall(jsonLib.decode, raw or "")
        if ok and type(decoded) == "table" then
            _data = decoded
        end
    end
    _data.tasks = _data.tasks or {}
    return _data
end

function _M.save()
    if not _data then return false end
    local ok, enc = pcall(jsonLib.encode, _data)
    if not ok then
        warnSafe("状态编码失败，本次未落盘: " .. tostring(enc))
        return false
    end
    if writeFile(_path, enc) ~= true then
        -- 静默失败会让每次重启都重跑所有任务，必须留痕
        warnSafe("状态写入失败，本次未落盘: " .. tostring(_path))
        return false
    end
    return true
end

-- 取某任务的记录；不存在则创建空记录（nextRun 为 nil，调用方视为立即到期）
function _M.get(taskName)
    -- _path 为 nil 说明 reset() 之后还没真正读过盘，必须先 load()
    -- （否则 _data 非空会跳过 load，_path 一直是 nil，save 写入必然失败）
    if not _data or not _path then _M.load() end
    local rec = _data.tasks[taskName]
    if not rec then
        rec = {}
        _data.tasks[taskName] = rec
    end
    return rec
end

function _M.reset()
    _data = { tasks = {} }
    _path = nil
end

return _M
