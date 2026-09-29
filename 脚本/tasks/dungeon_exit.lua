-- 脚本/tasks/dungeon_exit.lua
-- 副本出口：识别出口图标（小地图螺旋）→ 靠近 → 攻击键变放大镜 → 点击 → 弹窗确认离开
local logger = require("core.logger")
local dispatcher = require("core.dispatcher")
local exit = require("core.exit")

local M = { name = "副本出口" }

function M.readConfig(handle)
    -- 暂无专属设置页，使用默认参数
    return {
        maxMs = 90000,   -- 总超时
        walkMs = 600,    -- 每次前进时长
    }
end

function M.run(cfg)
    logger.info("=== 副本出口流程 ===")
    local hud = createHUD()
    local res = exit.run({
        maxMs = cfg.maxMs,
        walkMs = cfg.walkMs,
        onStep = function(i, info)
            local text = string.format("副本出口 第%d步", i)
            if info and info.exit then
                text = text .. string.format("  出口 sim=%.2f", info.exit.sim)
            end
            showHUD(hud, text, 15, "0xffffffff", "0xCC222222", 0, 20, 150, 520, 60)
        end,
    })
    hideHUD(hud)
    if res == "done" then
        logger.info("========== 已离开副本 ==========")
    else
        logger.warn("出口流程未完成: " .. tostring(res))
    end
    return res
end

dispatcher.register(M)

return M
