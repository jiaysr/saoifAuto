-- 脚本/tasks/dungeon_exit.lua
-- 副本出口：识别出口图标（小地图螺旋）→ 靠近 → 攻击键变放大镜 → 点击 → 弹窗确认离开
local logger = require("core.logger")
local dispatcher = require("core.dispatcher")
local exit = require("core.exit")

local vars = require("tasks.dungeon_exit.vars")   -- 变量集中在 vars.lua
local M = { name = "副本出口" }

-- H5 界面参数表（界面自动渲染表单）
    M.id, M.name, M.desc, M.schema, M.defaults = vars.id, vars.name, vars.desc, vars.schema, vars.defaults


M.desc = "副本出口自动寻路：识别出口图标 → 靠近 → 攻击键变放大镜后点击 → 弹窗确认离开。"

function M.readConfig(cfg)
    cfg = cfg or {}
    local d = M.defaults or {}
    local function num(k, def)
        local v = tonumber(cfg[k]); if v == nil then v = d[k] end
        if v == nil then v = def end
        return v
    end
    return {
        mode   = tostring(cfg.mode or d.mode or "auto"),
        maxMs  = num("maxMs", 120000),
        walkMs = num("walkMs", 600),
    }
end

function M.run(cfg)
    logger.info("=== 副本出口流程 ===")
    local hud = createHUD()
    local onStep = function(i, info)
        local text = string.format("副本出口 第%d步", i)
        if info and info.exit then
            text = text .. string.format("  出口 sim=%.2f", info.exit.sim)
        end
        showHUD(hud, text, 15, "0xffffffff", "0xCC222222", 0, 20, 150, 520, 60)
    end
    local res
    if cfg.mode == "mini" then
        res = exit.run({ maxMs = cfg.maxMs, onStep = onStep })
    elseif cfg.mode == "bigmap" then
        res = exit.run({ maxMs = cfg.maxMs, bigMap = true, onStep = onStep })
    else
        -- auto：小地图看不到出口时自动开大地图连走（实测 28~34s 出本）
        local auto = require("core.exit_auto")
        res = auto.run({ maxMs = cfg.maxMs })
    end
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
