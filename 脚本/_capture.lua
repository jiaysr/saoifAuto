-- 脚本/_capture.lua — 副本出口流程（自动模式：小地图看不到出口就开大地图）
local auto = require("core.exit_auto")
local ok, err = xpcall(function()
    local r = auto.run({ maxMs = 120000 })
    print("EXITRUN_AUTO result=" .. tostring(r))
end, function(e) return debug.traceback(e) end)
if not ok then print("EXITRUN_AUTO ERR: " .. tostring(err)) end
