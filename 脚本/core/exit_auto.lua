-- 脚本/core/exit_auto.lua
-- 副本出口 · 自动模式（v3：开图后连续走多步）
-- ==================== 依据（用户实测） ====================
-- · 小地图只显示附近范围，出口常在范围外 → 此时必须点开大地图找；
-- · 大地图不挡移动/点击/滑视角；开图后小地图面板被 CLOSE 盖住，
--   但「大地图上的玩家标记旁边一定有视角锥」→ 用 viewcone_at 在标记处读角（闭环）。
-- v3 改动：开图后不再"走一步就关"，而是在图上连续走 mapSteps 步
--          （每步重新定位玩家+出口 → 闭环对准 → 前进），
--          直到 到位 / 贴脸 / 被挡 / 出口脱离大地图 才关图回到主循环。
-- 依赖：core.exit、core.viewcone_at、core.templates、core.minimap、core.move
local logger = require("core.logger")
local mm = require("core.minimap")
local mv = require("core.move")
local ex = require("core.exit")
local tpl = require("core.templates")
local at = require("core.viewcone_at")

-- 大地图上出口螺旋实测约 0.56，默认 0.58 略高
if ex.CFG.bigExitSim > 0.52 then ex.CFG.bigExitSim = 0.52 end

-- 给 exit 打补丁：开图时以「大地图玩家标记」为极点读视野锥
-- ⚠ 必须先判"图开着"再退回原逻辑（原版兜底 mm.update 在开图时会返回垃圾值而非 nil）
local _origViewBearing = ex.viewBearing
ex.viewBearing = function()
    local mk = tpl.match("marker", ex.CFG.bigMapROI, 0.72)
    if mk then
        local r = at.bearingAt({ x = mk.x, y = mk.y }, { rMin = 12, rMax = 60 })
        if r then return r.bearing, string.format("bigmap(sim=%.2f)", mk.sim) end
    end
    return _origViewBearing()
end

local M = {}

M.CFG = {
    blindBeforeMap = 2,   -- 小地图连续看不到出口几次 → 开大地图
    mapSteps       = 5,   -- ★ 开图后连续走几步（每步重新定位+对准）
    arrivePx       = 25,  -- 与出口距离小于该值 → 视为贴脸，交给放大镜判定
    stuckPx        = 2,   -- 距离改善小于该值视为被挡
    walkMaxMs      = 600,
    walkMinMs      = 180,
    walkMsPerPx    = 11,
    blindMax       = 6,
    mapOpenMs      = 1400,
    mapCloseMs     = 700,
    alignTol       = 8,
}

function M.stepMs(d)
    local ms = math.floor(d * M.CFG.walkMsPerPx)
    if ms > M.CFG.walkMaxMs then ms = M.CFG.walkMaxMs end
    if ms < M.CFG.walkMinMs then ms = M.CFG.walkMinMs end
    return ms
end

-- 开环兜底：已知当前视野朝向时，朝 target 拖一次
function M.faceToOpen(target, known)
    local cur = known or ex.viewBearing()
    if not cur then return nil end
    local d = mm.diffTo180(target - cur)
    local px = d * ex.CFG.pxPerDeg
    if px > ex.CFG.turnMaxPx then px = ex.CFG.turnMaxPx end
    if px < -ex.CFG.turnMaxPx then px = -ex.CFG.turnMaxPx end
    local x0, y0 = ex.CFG.turnOrigin.x, ex.CFG.turnOrigin.y
    swipe(x0, y0, x0 + px, y0, math.min(450, math.max(140, math.abs(px) * 1.8)))
    return d
end

-- ★ 开图后连续走多步（图保持打开；边走边闭环对准）
-- 返回 实际步数, 结束原因(arrived/close/no_locate/blocked/steps)
function M.walkOnMap(maxSteps)
    local curB = ex.viewBearing()          -- 开图前测一次，供开环兜底
    ex.openBigMap(M.CFG.mapOpenMs)
    local stepN, reason = 0, "steps"
    local lastDist

    for i = 1, maxSteps do
        local mag = ex.findMagnifier()
        if mag then reason = "arrived" break end

        local loc, err = ex.locateOnBigMap()
        if not loc then reason = "no_locate:" .. tostring(err) break end

        if loc.dist <= M.CFG.arrivePx then reason = "close" break end
        if lastDist and (lastDist - loc.dist) < M.CFG.stuckPx then
            reason = "blocked" break
        end
        lastDist = loc.dist

        local dErr, why = ex.faceTo(loc.bearing, { tol = M.CFG.alignTol })
        if dErr == nil then
            dErr = M.faceToOpen(loc.bearing, curB)
            why = "open_loop"
        end
        logger.info(string.format("大地图[%d/%d]: 玩家=(%.0f,%.0f) 出口=(%.0f,%.0f) 距离=%.0f 方位=%.0f 对准=%s(%s) sim=%.2f/%.2f",
            i, maxSteps, loc.px, loc.py, loc.ex, loc.ey, loc.dist, loc.bearing,
            dErr and string.format("%+.1f°", dErr) or "nil", tostring(why), loc.playerSim, loc.exitSim))

        mv.forward(M.stepMs(loc.dist))
        sleep(220)
        stepN = i
    end

    ex.closeBigMap(M.CFG.mapCloseMs)
    return stepN, reason
end

function M.run(cfg)
    cfg = cfg or {}
    local deadline = tickCount() + (cfg.maxMs or 180000)
    local step, seeN, blind = 0, 0, 0

    logger.info("=== 副本出口（自动模式 v3：开图连走）===")

    local cleared = ex.dismissDialogs(2, 800)
    if cleared > 0 then
        logger.info("已清理残留弹窗 " .. cleared .. " 层")
        sleep(400)
    end

    while tickCount() < deadline do
        step = step + 1

        -- ① 到位
        local mag = ex.findMagnifier()
        if mag then
            logger.info(string.format("到达出口(放大镜 sim=%.2f) → 点击 (%d,%d)", mag.sim, mag.x, mag.y))
            tap(mag.x, mag.y)
            sleep(700)
            if ex.confirmLeave(6000) then
                ex.dismissDialogs(2, 800)
                logger.info("已确认离开副本 ✓")
                return "done"
            end
            logger.warn("未出现确认弹窗，再试一次")
            tap(mag.x, mag.y)
            sleep(800)
            if ex.confirmLeave(5000) then
                ex.dismissDialogs(2, 800)
                logger.info("已确认离开副本 ✓")
                return "done"
            end
            return "timeout"
        end

        -- ② 小地图能看到出口 → 小地图走一步
        local e = ex.findExit()
        if e then
            seeN, blind = 0, 0
            local dx, dy = e.x - mm.CENTER.x, e.y - mm.CENTER.y
            local d = math.sqrt(dx * dx + dy * dy)
            local dErr, why = ex.faceTo(mm.bearing(dx, dy), { tol = M.CFG.alignTol })
            logger.info(string.format("小地图: 距离=%.0fpx 对准=%s(%s)", d,
                dErr and string.format("%+.1f°", dErr) or "nil", tostring(why)))
            mv.forward(M.stepMs(d))
        else
            seeN = seeN + 1
            if seeN < M.CFG.blindBeforeMap then
                logger.info(string.format("小地图未显示出口(第%d次)，先直走一步", seeN))
                mv.forward(220)
            else
                seeN = 0
                -- ③ 出口不在小地图范围 → 开图连续走多步
                local n, why = M.walkOnMap(M.CFG.mapSteps)
                logger.info(string.format("大地图连走结束: %d 步, 原因=%s", n, tostring(why)))
                if tonumber(tostring(why):match("^no_locate")) then
                    blind = blind + 1
                    if blind > M.CFG.blindMax then
                        logger.warn("连续多次都定位不到出口，结束")
                        return "no_exit"
                    end
                else
                    blind = 0
                end
            end
        end
        sleep(150)
    end
    logger.warn("自动模式超时")
    return "timeout"
end

return M
