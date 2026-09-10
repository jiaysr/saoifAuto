-- 脚本/spike/lib/dummy.lua
-- 探针用：验证 require 的多级模块路径
-- 文件位置 脚本/spike/lib/dummy.lua ←→ require("spike.lib.dummy")

local _M = { tag = "spike-lib" }

function _M.hello()
    return "spike-lib ok"
end

return _M
