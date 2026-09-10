-- 脚本/ui/hud.lua
-- HUD 封装：任务只负责说「显示什么」，不管理句柄生命周期。
local _M = {}

local HUD = {}
HUD.__index = HUD

function _M.new(enabled, title)
    return setmetatable({ enabled = enabled and true or false, title = title or "", id = nil }, HUD)
end

function HUD:update(text)
    if not self.enabled then return end
    if not self.id then self.id = createHUD() end
    showHUD(self.id, self.title .. "\n" .. tostring(text),
        14, "0xffffffff", "0xCC222222", 0, 20, 180, 360, 120)
end

function HUD:close()
    if self.id then
        hideHUD(self.id)
        self.id = nil
    end
end

return _M
