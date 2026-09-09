-- 脚本/core/dispatcher.lua
-- 功能注册表：每个功能模块在加载时调用 register 把自己挂进来，
-- 主入口根据界面选择的功能名进行分发。新增功能只需：
--   1. 在 脚本/tasks/ 下新建模块并 register
--   2. 在 界面/saoif.ui 的 selFunction 下拉框中追加同名 <选项>

local _M = {}

_M._tasks = {}

function _M.register(mod)
    _M._tasks[#_M._tasks + 1] = mod
    return mod
end

function _M.all()
    return _M._tasks
end

function _M.find(name)
    for _, t in ipairs(_M._tasks) do
        if t.name == name then
            return t
        end
    end
    return nil
end

return _M
