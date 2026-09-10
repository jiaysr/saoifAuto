-- 脚本/tasks/fishing/config.lua
-- 钓鱼参数：默认值与读取。默认值只在这里写一份（XML 的 默认值 属性仅作首次运行的初值）。
local settings = require("core.settings")

local _M = {}

function _M.defaults()
    return {
        loopTime    = 45,    -- 单轮超时（秒），成功会重置计时
        maxCatch    = 0,     -- 目标次数，0 = 不限
        clickX      = 1173,  -- 开始 / 提竿按钮
        clickY      = 510,
        scanX       = 1015,  -- 浮标扫描列
        zoneY1      = 123,   -- 完美区域扫描范围
        zoneY2      = 523,
        showHud     = true,
        debugColors = false,
    }
end

-- 从已持久化的配置读取（page1 = 钓鱼参数）。
-- 注意：调度器执行任务时窗口早已关闭，没有 handle 可用，所以一律读配置文件；
-- 参数页只负责写入，lrjl 在关窗保存时落盘。从未保存过的项回落 defaults()。
function _M.load()
    local d = _M.defaults()
    local p = settings.pageOf("fishing", 1)
    return {
        loopTime    = settings.num(p.edLoopTime, d.loopTime),
        maxCatch    = settings.num(p.edMaxCatch, d.maxCatch),
        clickX      = settings.num(p.edClickX, d.clickX),
        clickY      = settings.num(p.edClickY, d.clickY),
        scanX       = settings.num(p.edScanX, d.scanX),
        zoneY1      = settings.num(p.edZoneY1, d.zoneY1),
        zoneY2      = settings.num(p.edZoneY2, d.zoneY2),
        showHud     = settings.bool(p.chkShowHud, d.showHud),
        debugColors = settings.bool(p.chkDebugColors, d.debugColors),
    }
end

return _M
