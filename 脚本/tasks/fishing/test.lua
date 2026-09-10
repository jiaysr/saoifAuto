-- 脚本/tasks/fishing/test.lua
-- 单任务调试：在游戏里直接跑钓鱼，不经过主界面与调度器。
-- 用法：把 脚本/saoif.lua 临时改成 require("tasks.fishing.test").run()
local task = require("tasks.fishing.task")
local config = require("tasks.fishing.config")

local _M = {}

function _M.run()
    print("[fishing.test] 直接跑一轮钓鱼（参数取自已持久化的配置，缺失则用默认值）")
    task.run(config.load(), { taskName = "fishing" })
end

return _M
