-- 脚本/core/registry.lua
-- 任务注册表：require 清单里的模块并建立 name -> 任务 的查找（取代 core/dispatcher.lua）
local taskModule = require("core.task")

local _M = {}

local _tasks = {}
local _byName = {}

-- 直接装入任务表数组（测试与内部使用）
function _M.loadTable(list)
    _tasks = {}
    _byName = {}
    for _, mod in ipairs(list) do
        local t = taskModule.normalize(mod)
        _tasks[#_tasks + 1] = t
        _byName[t.name] = t
    end
    return _tasks
end

-- 按 tasks/index.lua 的模块路径数组加载
function _M.load(paths)
    local mods = {}
    for _, path in ipairs(paths) do
        mods[#mods + 1] = require(path)
    end
    return _M.loadTable(mods)
end

function _M.all() return _tasks end

function _M.find(name) return _byName[name] end

return _M
