-- 脚本/core/state.lua
-- 运行时状态持久化：只放会随运行变化的东西
--   nextRun / successCount / failureStreak / lastResult
-- 位置：getWorkPath()/saoif_state/state.json
-- 注意：任务设置（启用/优先级/间隔）不在这里，见 core/settings.lua
local _M = {}

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
    if not ok then return false end
    return writeFile(_path, enc) == true
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
