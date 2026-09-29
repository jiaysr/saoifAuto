-- 脚本/core/facing_calib.lua
-- 角色朝向标定: 把 core.facing 的「标记旋转角」换算成罗盘方位
-- ==================== 原理 ====================
-- 角色行走时面朝行走方向; 而大地图是「北向上」的,
-- 因此「大地图上玩家坐标的位移方向」就是角色朝向的罗盘方位 —— 不依赖任何摇杆假设。
--     CALIB = 位移方位(罗盘) - 精灵旋转角(拼合图角度)
--     之后 facing.toBearing(angle) = angle + CALIB
-- 做法: 开大地图记下玩家坐标 P1 → 关图朝镜头前方走一段 → 停下读精灵角 A → 再开图记 P2
--       位移 = P2 - P1 (屏幕 dx 向右 = 东, dy 向下 = 南) → 方位 = atan2(dx, -dy)
-- 多轮取圆均值, 并给出离散度(spread)便于判断可信度。
--
-- 用法:
--   local cal = require("core.facing_calib")
--   local v, info = cal.calibrate({ trials = 3, verbose = true })   -- 重新标定
--   cal.save(v)                                                     -- 持久化
--   cal.applySaved()                                                -- 启动时套用
--   print(cal.statusText())                                          -- 查看当前标定
local _M = {}

local fc = require("core.facing")

_M.FILE = "facing_calib.txt"

local function dir() return getSdPath() .. "/saoif_tpl" end
local function path() return dir() .. "/" .. _M.FILE end

-- 保存/读取/套用标定值
function _M.save(v)
    if type(v) ~= "number" then return false end
    pcall(mkdir, dir())
    local f = io.open(path(), "w")
    if not f then return false end
    f:write(string.format("%.1f", v))
    f:close()
    return true
end

function _M.load()
    local f = io.open(path(), "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return tonumber(s)
end

function _M.applySaved()
    local v = _M.load()
    if v then fc.calib(v) end
    return v or fc.CALIB
end

function _M.statusText()
    local saved = _M.load()
    return string.format("当前 CALIB=%.1f  已保存=%s", fc.CALIB, saved and string.format("%.1f", saved) or "无")
end

local function diff180(d)
    d = d % 360
    if d > 180 then d = d - 360 end
    return d
end

-- 标定: 用大地图位移当基准(角色朝向 == 行走方向)
-- opts = { trials=3, walkMs=1300, minPx=6, verbose=false, tapOpen={x,y}, tapClose={x,y} }
-- 返回 calib(度), info{spread,n,samples} 或 nil, err
function _M.calibrate(opts)
    opts = opts or {}
    local okMv, mv = pcall(require, "core.move")
    if not okMv or not mv then return nil, "no_move" end
    local vc = require("core.viewcone")
    local openP = opts.tapOpen or { 1181, 100 }
    local closeP = opts.tapClose or { 1187, 107 }
    local trials = opts.trials or 3
    local lastErr = ""

    -- 只需要"玩家位置", 所以直接调 detectBigMap(不要求锥体可测, weak_cone 也能给位置)
    local function openMap()
        tap(openP[1], openP[2]); sleep(opts.openMs or 1500)
        for k = 1, 4 do
            local b, err = vc.detectBigMap()
            if b and b.x then return b end
            lastErr = tostring(err)
            sleep(250)
        end
        return nil
    end
    local function closeMap()
        tap(closeP[1], closeP[2]); sleep(opts.closeMs or 900)
    end

    local samples = {}
    for i = 1, trials do
        local p1 = openMap()
        if not p1 then
            if opts.verbose then print("CAL 第" .. i .. "轮: 开图取位置失败 " .. lastErr) end
        end
        closeMap()
        if p1 and p1.x then
            mv.forward(opts.walkMs or 1300)
            sleep(opts.settleMs or 450)
            local a = fc.detectStable(2, nil, { minVotes = 1, tol = 8 })
            local p2 = openMap()
            closeMap()
            if a and a.angle and p2 and p2.x then
                local dx, dy = p2.x - p1.x, p2.y - p1.y
                local dist = math.sqrt(dx * dx + dy * dy)
                if dist >= (opts.minPx or 6) then
                    local bearing = math.deg(math.atan2(dx, -dy)) % 360
                    samples[#samples + 1] = { bearing = bearing, angle = a.angle, dist = dist, sim = a.sim }
                    if opts.verbose then
                        print(string.format("CAL 第%d轮 位移方位=%.1f° 位移=%.1fpx 精灵角=%d° sim=%.2f",
                            i, bearing, dist, math.floor(a.angle + 0.5), a.sim or 0))
                    end
                elseif opts.verbose then
                    print(string.format("CAL 第%d轮 位移太小(%.1fpx), 跳过(可能被挡住)", i, dist))
                end
            elseif opts.verbose then
                print(string.format("CAL 第%d轮 采样不全: angle=%s p2=%s", i,
                    a and a.angle and "ok" or "nil", (p2 and p2.x) and "ok" or "nil"))
            end
        end
        if i < trials then sleep(opts.gapMs or 300) end
    end
    if #samples == 0 then return nil, "no_samples" end

    local vx, vy = 0, 0
    for _, s in ipairs(samples) do
        local a = math.rad((s.bearing - s.angle) % 360)
        vx = vx + math.cos(a)
        vy = vy + math.sin(a)
    end
    local calib = math.deg(math.atan2(vy, vx)) % 360
    local spread = 0
    for _, s in ipairs(samples) do
        local d = math.abs(diff180(((s.bearing - s.angle) % 360) - calib))
        if d > spread then spread = d end
    end
    fc.calib(calib)
    return calib, { spread = spread, n = #samples, samples = samples }
end

-- 自检: 走一步后比较「标定后的角色朝向」与「视野锥朝向」(行走时两者应接近)
function _M.verify(opts)
    opts = opts or {}
    local okMv, mv = pcall(require, "core.move")
    if not okMv or not mv then return nil, "no_move" end
    local vc = require("core.viewcone")
    mv.forward(opts.walkMs or 900)
    sleep(opts.settleMs or 400)
    local v = vc.detectStable(3, { minVotes = 2 })
    local a = fc.detectStable(2, nil, { minVotes = 1 })
    if not (v and v.bearing and a and a.angle) then return nil, "no_sample" end
    local facing = fc.toBearing(a.angle)
    return diff180(facing - v.bearing), { facing = facing, view = v.bearing, sim = a.sim, conf = v.conf }
end

return _M
