-- 脚本/core/viewcone_at.lua
-- 在任意屏幕位置测「视野锥」方向（大地图上的玩家标记旁边也有锥体）
-- 说明：core/viewcone.lua 的剖面核心只服务于固定极点(小地图)或它自己找到的环；
--       这里把同一套逻辑抽成「任意极点」版本，颜色规则/参数直接复用 vc.CFG。
local vc = require("core.viewcone")

local M = {}

local function isCone(r, g, b, cfg)
    if r < g then
        local lum = (r + g + b) / 3
        if lum > cfg.lumMin and (g - b) > cfg.gbMin and b < cfg.bMax and (r - b) > cfg.rbMin then
            local mx = r
            if g > mx then mx = g end
            if b > mx then mx = b end
            local mn = r
            if g < mn then mn = g end
            if b < mn then mn = b end
            return lum, mx - mn
        end
    end
    return nil
end

-- center = {x=,y=} 屏幕坐标(极点)
-- opts = { rMin=12, rMax=60, minN=20 }
-- 返回 { bearing=罗盘方位, screen=屏幕角, conf, n } 或 nil, err
function M.bearingAt(center, opts)
    opts = opts or {}
    local cfg = vc.CFG
    local rMin = opts.rMin or 12
    local rMax = opts.rMax or 60
    local pad = rMax + 4
    local x1, y1 = center.x - pad, center.y - pad
    local w, h, arr = getScreenPixel(x1, y1, center.x + pad, center.y + pad)
    if not w or w <= 0 then return nil, "no_shot" end

    local prof = {}
    for i = 1, 360 do prof[i] = 0 end
    local n = 0
    for yy = y1, y1 + h - 1 do
        local base = (yy - y1) * w
        local dy = yy - center.y
        for xx = x1, x1 + w - 1 do
            local dx = xx - center.x
            local d2 = dx * dx + dy * dy
            if d2 >= rMin * rMin and d2 <= rMax * rMax then
                local r, g, b = colorToRGB(arr[base + (xx - x1 + 1)])
                local lum, sat = isCone(b, g, r, cfg)   -- 数组是 BBGGRR: 真实 RGB = (b,g,r)
                if lum and sat < cfg.satMax then
                    local deg = math.deg(math.atan2(dy, dx))
                    if deg < 0 then deg = deg + 360 end
                    local bin = math.floor(deg) % 360 + 1
                    prof[bin] = prof[bin] + (lum - cfg.lumMin)
                    n = n + 1
                end
            end
        end
    end
    if n < (opts.minN or 20) then return nil, "no_cone(n=" .. n .. ")" end

    local k, half = cfg.smoothK, math.floor(cfg.smoothK / 2)
    local sm = {}
    for i = 1, 360 do
        local s = 0
        for j = -half, half do s = s + prof[(i - 1 + j) % 360 + 1] end
        sm[i] = s / k
    end
    local sorted = {}
    for i = 1, 360 do sorted[i] = sm[i] end
    table.sort(sorted)
    local floor = (sorted[180] + sorted[181]) / 2
    local vx, vy, tot = 0, 0, 0
    local energies = {}
    for i = 1, 360 do
        local v = sm[i] - floor
        if v > 0 then
            local a = math.rad(i - 1)
            vx = vx + v * math.cos(a)
            vy = vy + v * math.sin(a)
            tot = tot + v
        end
        energies[i] = v > 0 and v or 0
    end
    if tot <= 0 then return nil, "no_cone" end
    local screen = math.deg(math.atan2(vy, vx))
    if screen < 0 then screen = screen + 360 end
    table.sort(energies, function(a, b) return a > b end)
    local top, all = 0, 0
    for i = 1, 360 do
        all = all + energies[i]
        if i <= cfg.bandBins then top = top + energies[i] end
    end
    return {
        bearing = vc.screenToCompass(screen),
        screen = screen,
        conf = all > 0 and top / all or 0,
        n = n,
    }
end

return M
