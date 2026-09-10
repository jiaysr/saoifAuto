-- 脚本/tasks/fishing/task.lua
-- 自动钓鱼。流程与原 脚本/tasks/fishing.lua 一致，仅改为使用框架能力。
local logger = require("core.logger")
local pixel  = require("vision.pixel")
local rule   = require("vision.rule")
local hud    = require("ui.hud")
local A      = require("tasks.fishing.assets")
local config = require("tasks.fishing.config")

local NEEDLE_TIMEOUT        = 6000
local CLONE_CONFIRM_FRAMES  = 5

local M = {
    name = "fishing",
    title = "钓鱼",
    ui = "tasks/fishing.ui",
    enabled = true,
    priority = 5,
    interval = { success = 1, failure = 1 },
}

-- 不带 handle：调度器执行时没有窗口，配置一律从已持久化的文件读
function M.readConfig()
    return config.load()
end

function M.run(cfg, ctx)
    cfg = cfg or config.load()
    local successCount = 0
    local hudView = hud.new(cfg.showHud, "钓鱼中")

    local function updateHud(state)
        hudView:update(string.format("[%s] 成功 %d", state, successCount))
    end

    logger.info("=== 开始钓鱼 ===")

    setSnapCacheTime(0)

    if cfg.debugColors then
        logger.info("首帧颜色采样:")
        rule.dumpPoints(A.DO1.str, "DO1")
        rule.dumpPoints(A.TARGET.str, "Target")
    end

    local endTime    = tickCount() + cfg.loopTime * 1000
    local cloneSkip  = 0
    local pullPhase  = false
    local obsPos, obsTick

    updateHud("待机")

    while tickCount() < endTime do
        local do1        = rule.appear(A.DO1)
        local do4        = rule.appear(A.DO4)
        local do3Matched = rule.appear(A.DO3)
        local textMatched = rule.appear(A.TARGET)

        if do1 then
            logger.info("点击开始")
            tap(cfg.clickX, cfg.clickY)
            pullPhase = false
            updateHud("抛竿")
        end

        if do4 then
            logger.info("提竿")
            tap(cfg.clickX, cfg.clickY)
            pullPhase = true
            obsPos, obsTick = nil, nil
            updateHud("提竿")
        end

        if pullPhase then
            local now = tickCount()
            local pos = pixel.findNeedle(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
            if pos then
                if obsPos and pos ~= obsPos and obsTick then
                    local dt = now - obsTick
                    if dt > 0 then
                        logger.info(string.format("浮标 y=%3d (%+d) 间隔=%2dms 速度=%6.0f px/s",
                            pos, pos - obsPos, dt, math.abs(pos - obsPos) * 1000 / dt))
                    end
                end
                obsPos, obsTick = pos, now
            else
                obsPos, obsTick = nil, nil
            end
        end

        if textMatched and not do3Matched then
            local pStart, pEnd = pixel.findPerfectZone(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
            if pStart then
                logger.info(string.format("完美区域: %d-%d", pStart, pEnd))
                updateHud("追踪浮标")
                local needleEnd = tickCount() + NEEDLE_TIMEOUT
                while tickCount() < needleEnd do
                    local pos = pixel.findNeedle(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
                    if pos and pos >= pStart + 5 and pos <= pEnd + 5 then
                        logger.info(string.format("命中! pos=%d", pos))
                        tap(cfg.clickX, cfg.clickY)
                        sleep(1000)
                        break
                    end
                    sleep(5)
                end
            end
        end

        if not textMatched and do3Matched then
            cloneSkip = cloneSkip + 1
            if cloneSkip >= CLONE_CONFIRM_FRAMES then
                cloneSkip = 0
                if rule.appearThenClick(A.CLONE) then
                    successCount = successCount + 1
                    logger.info(string.format("钓鱼成功! +1 (共 %d)", successCount))
                    updateHud("结算")
                    pullPhase = false
                    endTime = tickCount() + cfg.loopTime * 1000
                    sleep(1000)
                end
            end
        end

        if cfg.maxCatch > 0 and successCount >= cfg.maxCatch then
            logger.info(string.format("已达目标次数 %d，提前结束", cfg.maxCatch))
            break
        end

        if ctx and ctx.shouldStop and ctx.shouldStop() then
            logger.info("收到停止信号，结束钓鱼")
            break
        end

        sleep(30)
    end

    hudView:close()
    setSnapCacheTime(100)
    logger.info(string.format("========== 结束，共钓鱼 %d 次 ==========", successCount))
end

return M
