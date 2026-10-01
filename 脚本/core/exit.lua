-- 脚本/core/exit.lua
-- 副本出口：对准（镜头转向出口）→ 直走 → 交互（放大镜）→ 确认离开（OK）
-- ==================== v5.1 改动（2026-09-28） ====================
-- ① 大地图模式：有些副本（空間：第N層）小地图上的玩家标记不在中心，
--    按 mm.CENTER 算出口方位会错 → 对准来回摆、走不动。
--    用户实测：这类副本点开大地图后可同时看到玩家与出口，且大地图不挡移动/点击/滑视角。
-- ② 大地图上的玩家标记 = 与小地图同款的「白色水滴」→ 直接用 templates 里的
--    marker 模板(23x20)匹配定位，比环评分稳定（环评分在这类大图上会 no_ring）。
-- ③ 出口 = exit_spiral 模板（大地图上图标更小，门限降到 0.58）。
-- 流程：开图 → marker 找玩家 + exit_spiral 找出口 → 北向上地图算方位
--       → faceTo 对准 → mv.forward 直走 → 放大镜出现即到位 → 点击/确认/关多层弹窗。
--
-- 小地图模式（玩家在中心，v4.1）为默认；cfg.bigMap = true 切到大地图模式。
-- 依赖：core.viewcone、core.move、core.minimap、core.templates
local logger = require("core.logger")
local mm = require("core.minimap")
local mv = require("core.move")
local tpl = require("core.templates")
local vc = require("core.viewcone")

local M = {}

M.CFG = {
    exitROI = { 1090, 5, 1275, 195 },   -- 小地图区域（找出口螺旋）
    exitSim = 0.68,
    magROI  = { 1095, 430, 1265, 610 }, -- 放大镜所在按钮区
    magSim  = 0.68,
    okROI   = { 500, 455, 950, 620 },   -- 弹窗按钮区（放宽以覆盖两层弹窗）
    okSim   = 0.72,
    tmpDir  = "saoif_tpl",

    -- 大地图模式
    bigMapROI    = { 150, 80, 1020, 640 }, -- 大地图搜索区(覆盖圆形雷达)
    bigMarkerSim = 0.60,                   -- 玩家白水滴模板门限
    bigExitSim   = 0.58,                   -- 出口螺旋门限
    bigOpenTap   = { 1181, 100 },
    bigCloseTap  = { 1187, 107 },

    -- 对准（镜头转向出口）
    alignTol   = 8,
    pxPerDeg   = 2.5,
    turnOrigin = { x = 700, y = 150 },
    turnMaxPx  = 220,
    -- 前进
    msPerPx    = 11,
    stepMinMs  = 140,
    stepMaxMs  = 600,
    arrivePx   = 22,
}

function M.findExit()
    local r, low = tpl.match("exit_spiral", M.CFG.exitROI, M.CFG.exitSim)
    if r then
        local dx, dy = r.x - mm.CENTER.x, r.y - mm.CENTER.y
        if dx * dx + dy * dy < 25 * 25 then return nil, r end
    end
    return r, low
end
function M.findMagnifier() return tpl.match("magnifier", M.CFG.magROI, M.CFG.magSim) end
function M.findOk()        return tpl.match("ok_btn", M.CFG.okROI, M.CFG.okSim) end

function M.confirmLeave(waitMs, touchDx, touchDy)
    waitMs = waitMs or 5000
    local deadline = tickCount() + waitMs
    local low
    repeat
        local ok, l = M.findOk()
        low = l or low
        if ok then
            logger.info(string.format("确认弹窗: sim=%.2f → 点击 (%d,%d)", ok.sim, ok.x + (touchDx or 0), ok.y + (touchDy or 0)))
            tap(ok.x + (touchDx or 0), ok.y + (touchDy or 0))
            sleep(600)
            return true, ok.sim
        end
        sleep(250)
    until tickCount() >= deadline
    return false, low and low.sim or -1
end

function M.dismissDialogs(tries, gapMs)
    tries = tries or 3
    local n = 0
    for i = 1, tries do
        local ok = M.findOk()
        if not ok then break end
        logger.info(string.format("关闭弹窗(第%d层) sim=%.2f → 点击 (%d,%d)", i, ok.sim, ok.x, ok.y))
        tap(ok.x, ok.y)
        n = n + 1
        sleep(gapMs or 800)
    end
    return n
end

function M.viewBearing()
    local v = vc.detectStable(2, { minVotes = 1 })
    if v and v.bearing then return v.bearing, "viewcone" end
    local r = mm.update()
    if r and r.ok and r.yaw then return r.yaw, "minimap" end
    local r2 = mm.updateEx()
    if r2 and r2.marker then return r2.marker.ang, "markerEx" end
    return nil
end

function M.faceTo(target, opts)
    opts = opts or {}
    local tol = opts.tol or M.CFG.alignTol
    local maxIter = opts.maxIter or 5
    local cfg = M.CFG
    local last
    for i = 1, maxIter do
        local cur = M.viewBearing()
        if not cur then return nil, "no_yaw" end
        local d = mm.diffTo180(target - cur)
        last = d
        if math.abs(d) <= tol then return d, "ok" end
        local px = d * cfg.pxPerDeg
        if px > cfg.turnMaxPx then px = cfg.turnMaxPx end
        if px < -cfg.turnMaxPx then px = -cfg.turnMaxPx end
        local x0, y0 = cfg.turnOrigin.x, cfg.turnOrigin.y
        swipe(x0, y0, x0 + px, y0, math.min(450, math.max(140, math.abs(px) * 1.8)))
        sleep(300)
    end
    return last, "max_iter"
end

-- ==================== 大地图模式 ====================
function M.openBigMap(waitMs) tap(M.CFG.bigOpenTap[1], M.CFG.bigOpenTap[2]); sleep(waitMs or 1500) end
function M.closeBigMap(waitMs) tap(M.CFG.bigCloseTap[1], M.CFG.bigCloseTap[2]); sleep(waitMs or 900) end

-- 在大地图上找「玩家(白水滴)」与「出口(螺旋)」，返回方位/距离
function M.locateOnBigMap()
    -- 玩家：优先白色水滴模板(与 vc 的环评分相比, 在这种大图上更稳)
    local player, plow = tpl.match("marker", M.CFG.bigMapROI, M.CFG.bigMarkerSim)
    if not player then
        local b = vc.detectBigMap()
        if b then player = { x = b.x, y = b.y, sim = b.ringS or 0 } end
    end
    if not player then
        return nil, string.format("no_player(marker_low=%.2f)", plow and plow.sim or -1)
    end

    local ex, elow = tpl.match("exit_spiral", M.CFG.bigMapROI, M.CFG.bigExitSim)
    if not ex then
        return nil, string.format("no_exit(low=%.2f)", elow and elow.sim or -1)
    end

    local dx, dy = ex.x - player.x, ex.y - player.y
    local dist = math.sqrt(dx * dx + dy * dy)
    local bearing = math.deg(math.atan2(dx, -dy)) % 360      -- 地图北向上
    return {
        px = player.x, py = player.y, ex = ex.x, ey = ex.y,
        bearing = bearing, dist = dist,
        playerSim = player.sim or 0, exitSim = ex.sim,
    }
end

function M.runBigMap(cfg)
    cfg = cfg or {}
    local deadline = tickCount() + (cfg.maxMs or 120000)
    local step, failN = 0, 0

    logger.info("=== 副本出口（大地图模式 v5.1）===")
    M.closeBigMap(600)
    M.openBigMap(1500)

    while tickCount() < deadline do
        step = step + 1

        local mag = M.findMagnifier()
        if mag then
            logger.info(string.format("到达出口(放大镜 sim=%.2f) → 点击 (%d,%d)", mag.sim, mag.x, mag.y))
            tap(mag.x, mag.y)
            sleep(700)
            if M.confirmLeave(6000) then
                M.dismissDialogs(2, 800)
                M.closeBigMap(600)
                logger.info("已确认离开副本 ✓")
                return "done"
            end
            logger.warn("未出现确认弹窗，再试一次")
            tap(mag.x, mag.y)
            sleep(800)
            if M.confirmLeave(5000) then
                M.dismissDialogs(2, 800)
                M.closeBigMap(600)
                logger.info("已确认离开副本 ✓")
                return "done"
            end
            return "timeout"
        end

        local loc, err = M.locateOnBigMap()
        if not loc then
            failN = failN + 1
            logger.warn(string.format("大地图定位失败(%s) 第%d次", tostring(err), failN))
            if failN >= 8 then
                M.closeBigMap(600)
                return "no_exit"
            end
        else
            failN = 0
            local dErr, why = M.faceTo(loc.bearing)
            logger.info(string.format("大地图: 玩家=(%.0f,%.0f) 出口=(%.0f,%.0f) 距离=%.0f 方位=%.0f 对准=%s(%s) sim=%.2f/%.2f",
                loc.px, loc.py, loc.ex, loc.ey, loc.dist, loc.bearing,
                dErr and string.format("%+.1f°", dErr) or "nil", tostring(why), loc.playerSim, loc.exitSim))
            local ms = math.floor(loc.dist * M.CFG.msPerPx)
            if ms > M.CFG.stepMaxMs then ms = M.CFG.stepMaxMs end
            if ms < M.CFG.stepMinMs then ms = M.CFG.stepMinMs end
            mv.forward(ms)
            if cfg.onStep then cfg.onStep(step, loc) end
        end
        sleep(200)
    end
    M.closeBigMap(600)
    logger.warn("大地图模式超时")
    return "timeout"
end

-- ==================== 小地图模式（玩家在中心）====================
function M.run(cfg)
    cfg = cfg or {}
    if cfg.bigMap then return M.runBigMap(cfg) end
    local deadline = tickCount() + (cfg.maxMs or 90000)
    local step = 0
    local notFound = 0
    local lastExit
    local cfgTol = cfg.alignTol or M.CFG.alignTol

    local function distFrom(ex)
        local dx, dy = ex.x - mm.CENTER.x, ex.y - mm.CENTER.y
        return math.sqrt(dx * dx + dy * dy), mm.bearing(dx, dy)
    end

    local function stableExit(e)
        if not e then return nil end
        if lastExit then
            local jump = math.sqrt((e.x - lastExit.x) ^ 2 + (e.y - lastExit.y) ^ 2)
            if jump > 30 and e.sim < lastExit.sim + 0.05 then
                logger.info(string.format("出口位置跳变(%.0fpx)，本帧忽略", jump))
                return nil
            end
        end
        lastExit = e
        return e
    end

    logger.info("=== 副本出口（v5.1 小地图模式）===")

    local cleared = M.dismissDialogs(2, 800)
    if cleared > 0 then
        logger.info("已清理残留弹窗 " .. cleared .. " 层")
        sleep(400)
    end

    while tickCount() < deadline do
        step = step + 1

        local mag = M.findMagnifier()
        if mag then
            logger.info(string.format("到达出口(放大镜 sim=%.2f) → 点击 (%d,%d)", mag.sim, mag.x, mag.y))
            tap(mag.x, mag.y)
            sleep(700)
            if M.confirmLeave(6000) then
                M.dismissDialogs(2, 800)
                logger.info("已确认离开副本 ✓")
                return "done"
            end
            logger.warn("未出现确认弹窗，再试一次")
            tap(mag.x, mag.y)
            sleep(800)
            if M.confirmLeave(5000) then
                M.dismissDialogs(2, 800)
                logger.info("已确认离开副本 ✓")
                return "done"
            end
            return "timeout"
        end

        local e = stableExit(M.findExit())
        if not e then
            notFound = notFound + 1
            if notFound <= 12 then
                logger.info(string.format("未识别到出口(第%d次)，向前小步试探", notFound))
                mv.forward(150)
                sleep(220)
            else
                logger.warn("连续未识别到出口图标，结束")
                return "no_exit"
            end
        else
            notFound = 0
            local d, bearing = distFrom(e)
            local dErr, why = M.faceTo(bearing, { tol = cfgTol })
            if dErr == nil then
                logger.warn(string.format("出口: 距离=%.0fpx 方位=%.0f° 但读不到视野朝向(%s)，直接前进", d, bearing, tostring(why)))
            else
                logger.info(string.format("出口: 距离=%.0fpx 方位=%.0f° 对准误差=%+.1f° (%s)", d, bearing, dErr, why))
            end
            local ms = math.floor(d * M.CFG.msPerPx)
            if ms > M.CFG.stepMaxMs then ms = M.CFG.stepMaxMs end
            if ms < M.CFG.stepMinMs then ms = M.CFG.stepMinMs end
            mv.forward(ms)
            sleep(220)
            if cfg.onStep then cfg.onStep(step, { exit = e, dist = d, bearing = bearing, alignErr = dErr }) end
        end
        sleep(150)
    end
    logger.warn("出口流程超时")
    return "timeout"
end

return M
