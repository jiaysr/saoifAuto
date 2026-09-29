-- 脚本/core/move.lua
-- 移动控制（虚拟摇杆）
-- ==================== 机制说明（2026-09-28 云真机 Pixel 4 实测） ====================
-- 摇杆中心 (164,574)：拖到某方向并按住 = 持续朝该方向移动；松手即停。
-- 摇杆方向相对镜头：上 = 视野锥（镜头）正前方（用户确认的游戏机制）。
--
-- 实测要点：
-- 1) 本环境下 touchDown/touchMove 注入的「按住」不被游戏摇杆采纳（角色不动），
--    而 swipe()（IDE 内置手势）能驱动摇杆 → 持续移动用「单次长 swipe」模拟：
--    手指从中心缓慢拖到目标点，整个拖动过程角色都在移动（持续时间≈ms）。
-- 2) 摇杆有效响应区集中在左下 (110~240, 520~600)；如无响应可微调 CFG.center。
-- 3) 角色会被墙/障碍挡住 → 用 M.driftCheck() 或位移检测判断是否真的在走。
-- 4) 【重要】游戏内有菜单/弹窗打开时，一切移动触控无效（表现为位移=0、漂移=0）。
--    可用 keyPress(4)（返回键数字码）或左边缘手势关闭菜单。
-- 5) 方向语义提供开关 CFG.worldRelative：
--      false（默认，按用户说明）= 摇杆相对镜头：rel = 目标罗盘 - 镜头罗盘
--      true  = 摇杆直接对应世界方向
--    ⚠️ 小镇等场景里 minimap 的锥体朝向读数可能不可靠（位置读数可靠），
--       用 dirTo 走精确罗盘方向前，建议先在开阔地实测校准一次。
-- 6) 方向语义已确认（2026-09-28 15:47，用户见证：视角朝西）：
--      镜头读数 268.9°≈西 ✓；forward(1.5s) 位移方向 296°（≈西偏北 27°）
--      →【摇杆是镜头相对，"上"≈视野锥方向】与用户描述一致；
--      残余 27° 偏差来自摇杆中心未对准（有效中心约 x≈120~135），
--      可用 CFG.pushBiasDeg=-27 校正，或把 centerX 调到 ~135 后重测。
--
-- 用法：
--   local mv = require("core.move")
--   mv.forward(800)              -- 朝视野锥（镜头前方）走 800ms
--   mv.move(90, 1000)            -- 摇杆向右（相对镜头）走 1s
--   mv.dirTo(0, 1500)            -- 朝世界北走 1.5s（按镜头自动换算）

local logger = require("core.logger")
local mm = require("core.minimap")

local M = {}

M.CFG = {
    centerX = 164,        -- 摇杆中心 X
    centerY = 574,        -- 摇杆中心 Y
    radius = 88,          -- 拖拽半径（像素）
    pushBiasDeg = 0,      -- 上推方向系统偏差补偿（实测约 +27°：上推实际偏右，可设 -27 校正）
    minSwipeMs = 200,     -- 单次 swipe 最短时长
    maxSwipeMs = 8000,    -- 单次 swipe 最长时长
    slowPush = true,      -- true=长 swipe 慢拖（持续移动）；false=快速推到满舵
    fastPushMs = 150,     -- slowPush=false 时的推杆时长
    worldRelative = false,-- 方向语义开关（见头注释第 4 条）
    finger = 1,           -- hold 模式手指编号（swipe 模式不用）
    holdMode = false,     -- true=尝试 touchDown 按住（本机无效，保留兼容）
}

local holding = false

-- 脚本退出兜底：若 hold 模式还按着，自动松手
local exitHooked = false
local function hookExit()
    if exitHooked then return end
    exitHooked = true
    pcall(function()
        LuaEngine.registerExitCallback(function()
            if holding then
                pcall(touchUp, M.CFG.finger)
                holding = false
            end
        end)
    end)
end

-- 当前镜头罗盘角（minimap 优先，失败返回 nil）
function M.yaw()
    local r = mm.update()
    if r and r.ok and r.yaw then return r.yaw end
    local r2 = mm.updateEx()
    if r2 and r2.marker then return r2.marker.ang end
    return nil
end

-- 摇杆相对角 → 触点坐标（relDeg: 0=上，顺时针）
-- 含 pushBiasDeg 偏差补偿（实测上推约偏右 27°）
function M.point(relDeg, radius)
    radius = radius or M.CFG.radius
    relDeg = relDeg - (M.CFG.pushBiasDeg or 0)
    local rad = math.rad(relDeg)
    return M.CFG.centerX + math.sin(rad) * radius,
           M.CFG.centerY - math.cos(rad) * radius
end

-- 世界罗盘方向 → 摇杆相对角
function M.compassToRel(compassDeg, yaw)
    if M.CFG.worldRelative then return compassDeg % 360, yaw end
    yaw = yaw or M.yaw() or 0
    return (compassDeg - yaw) % 360, yaw
end

-- 持续移动 ms 毫秒（relDeg: 摇杆相对角，0=视野锥方向/上）
-- swipe 模式：一次长 swipe；hold 模式：touchDown 按住（本机通常无效）
function M.move(relDeg, ms, radius)
    if ms <= 0 then return end
    local tx, ty = M.point(relDeg, radius)
    if M.CFG.holdMode then
        hookExit()
        if not holding then
            touchDown(M.CFG.finger, M.CFG.centerX, M.CFG.centerY)
            sleep(60)
        end
        local steps = 12
        for i = 1, steps do
            touchMove(M.CFG.finger, M.CFG.centerX + (tx - M.CFG.centerX) * i / steps,
                M.CFG.centerY + (ty - M.CFG.centerY) * i / steps)
            sleep(12)
        end
        holding = true
        sleep(math.max(ms - 150, 0))
        M.stop()
        return
    end
    -- swipe 模式
    local dur = ms
    if dur < M.CFG.minSwipeMs then dur = M.CFG.minSwipeMs end
    if dur > M.CFG.maxSwipeMs then dur = M.CFG.maxSwipeMs end
    if M.CFG.slowPush then
        swipe(M.CFG.centerX, M.CFG.centerY, tx, ty, dur)
    else
        -- 快速推到位，再保持（部分机型支持）
        touchDown(M.CFG.finger, M.CFG.centerX, M.CFG.centerY)
        sleep(60)
        touchMoveEx(M.CFG.finger, tx, ty, M.CFG.fastPushMs)
        sleep(math.max(ms - M.CFG.fastPushMs - 60, 0))
        touchUp(M.CFG.finger)
    end
end

-- 朝视野锥方向（摇杆向上）移动 ms 毫秒
function M.forward(ms, radius)
    M.move(0, ms, radius)
end

-- 朝世界罗盘方向移动 ms 毫秒（按 CFG.worldRelative 换算）
-- yawOverride: 可传入外部校正过的镜头角（如防翻转修正后）
function M.dirTo(compassDeg, ms, radius, yawOverride)
    local rel, yaw = M.compassToRel(compassDeg, yawOverride)
    M.move(rel, ms, radius)
    return rel, yaw
end

-- 按住式控制（hold 模式用；swipe 模式为兼容空实现）
function M.start(relDeg, radius)
    M.move(relDeg, M.CFG.minSwipeMs, radius)
end

function M.stop()
    if holding then
        pcall(touchUp, M.CFG.finger)
        holding = false
    end
end

function M.isHolding()
    return holding
end

-- 强制释放全部手指（异常恢复）
function M.reset()
    for id = 0, 4 do
        pcall(touchUp, id)
    end
    holding = false
    sleep(120)
end

-- 漂移检测：无指令时角色是否仍在移动（返回位移 px）
function M.driftCheck(ms)
    ms = ms or 1000
    local function pos()
        local r = mm.update()
        if r and r.ok and r.markerX then return r.markerX, r.markerY end
        local r2 = mm.updateEx()
        if r2 and r2.marker then return r2.marker.x, r2.marker.y end
        return nil
    end
    local x1, y1 = pos()
    sleep(ms)
    local x2, y2 = pos()
    if not (x1 and x2) then return nil end
    return math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
end

return M
