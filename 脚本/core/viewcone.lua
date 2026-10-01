-- 脚本/core/viewcone.lua
-- SAOIF 视野锥(镜头朝向)识别 —— 支持两种界面
--   ① 小地图(常规界面): 玩家白环恒定在 (1181,100), 直接做极坐标剖面。
--   ② 大地图(点小地图展开): 白环位置不固定, 先找视野锥(楔形)与白环, 再做极坐标剖面。
-- 思路参考 genshin_impact_assistant (source/map/detection/minimap.py _predict_rotation):
--   把标记周围的环形区域按角度展开成一维剖面, 在剖面上定位视野锥, 由锥中心得到镜头方位。
-- 本游戏适配:
--   - 地图北向上; 视野锥 = 从标记出发的半透明淡黄绿色扇形(近亮远暗的渐变);
--   - 无世界地图可做背景差分, 用「颜色规则 + 亮度权重」提取锥体像素:
--         lum>145, g>b, g>=r, b<210, 饱和度<85, r-b>-95
--     饱和度上限用于排除绿色 NPC 点与黄色罗盘/文字图标(它们更艳);
--   - 锥体非 90°, 不做左右边缘配对, 用去噪底后的圆均值求锥中心。
--
-- 用法:
--   local vc = require("core.viewcone")
--   local r = vc.detect()                 -- 小地图: {bearing, screen, conf, n, center}
--   local b, err = vc.detectBigMap()      -- 大地图: 额外返回 x,y(玩家屏幕坐标) 与 ringR/ringS/score
--   print(vc.compassText(r.bearing))      -- "北/东北/东/..."
--
-- 大地图模式说明(detectBigMap):
--   点小地图展开后白环不再固定, 且地图上有很多白色图标, 因此:
--     ① 先按"圆环特征"找玩家白环: 白像素质心聚类 → bbox 10~34px → 环评分
--        (半径 5..11 圆周白点占比 - 内部白点占比, ≥0.55 视为环);
--     ② 环心用全分辨率白像素质心细化;
--     ③ 再以环心为极点做极坐标剖面(半径 12..55)求锥体方向, 要求 conf≥0.80 且锥体像素≥40;
--     ④ 多个环候选时取 conf/环评分综合最高者。
--   失败时: 返回 nil + err(no_shot / no_ring / weak_cone); weak_cone 时仍返回位置但 bearing=nil。
--
-- 实测(2026-09-28, 1280x720, 城镇大地图):
--   小地图: 重复 3 次读数全同(339.7°, conf .95); 与 core/minimap 的 ringConeScan 相差 0.5°;
--           右拖 100px×8 读数单调 105→212→259→306→342→25→68 (约 2.2~2.7 px/度);
--           单次 120~350ms。
--   大地图: 玩家环定位稳定(4 次均为 (786,336), ringR=7, ringS=0.90);
--           与小地图基准对比误差 +1.9° / -3.1° / -3.7° / -12.0°(最差一次锥体被图标遮挡);
--           单次 230~560ms。
--   注意事项: 地图半透明叠加在 3D 场景上, 深色地面上锥体对比度下降, 误差会变大;
--             conf<0.85 或 n 偏小时建议多帧投票。

local _M = {}

-- ==================== 区域/参数 ====================
-- 小地图(常规界面)
_M.REGION = { x1 = 1088, y1 = 0, x2 = 1279, y2 = 199 }
_M.CENTER = { x = 1181, y = 100 }

-- 大地图(展开界面): 地图面板 + 需要排除的 UI(底部道具栏、小地图右下 "+" 按钮)
_M.BM_REGION = { x1 = 300, y1 = 225, x2 = 905, y2 = 520 }
_M.BM_EXCLUDE = {
    { x1 = 348, y1 = 416, x2 = 958, y2 = 516 },    -- 底部道具栏
    { x1 = 1232, y1 = 168, x2 = 1280, y2 = 200 },  -- 小地图右下 "+"
}

_M.CFG = {
    lumMin  = 145,   -- 锥体像素最低亮度
    satMax  = 85,    -- 饱和度上限(排除绿色NPC点/黄色图标)
    gbMin   = 5,     -- g-b 下限(偏绿)
    rbMin   = -95,   -- r-b 下限(排除蓝青地形)
    bMax    = 210,   -- 蓝分量上限(排除近白)
    rMin    = 12,    -- 小地图环形内半径(避开白环)
    rMax    = 50,    -- 小地图环形外半径
    smoothK = 7,     -- 角度剖面平滑核(环形箱式)
    bandBins = 60,   -- 置信度统计的带内桶数
}

_M.BM_CFG = {
    step     = 2,    -- 扫描步长
    cell     = 8,    -- 聚类单元
    minPx    = 12,   -- 锥体簇最小采样点数(step=2 时约合 48 真实像素)
    apexFrac = 0.30, -- 取最亮的该比例像素作为锥尖估计
    ringR    = 22,   -- 白环搜索半径(锥尖附近)
    ringMin  = 6,    -- 白环最少像素
    maxSpread = 150, -- 锥体簇相对锥尖的最大角展宽(超过视为圆形图标)
    rMin     = 12,   -- 大地图剖面内半径
    rMax     = 55,   -- 大地图剖面外半径
    minConf  = 0.80, -- 单帧最低置信度
}

-- 多帧投票参数
_M.VOTE = {
    frames   = 3,    -- 采样帧数
    minConf  = 0.85, -- 单帧 conf 门限(低于此值不投票)
    tol      = 12,   -- 角度聚类容差(度), 簇内视为"同一朝向"
    minVotes = 2,    -- 最少有效票数, 不足则不输出
    posTol   = 30,   -- 位置聚类容差(px, 大地图用)
    intervalMs = 120,-- 采样间隔
}

-- 大地图展开时右上角 CLOSE 按钮的底色(实测 0x258396 一带)
_M.BM_OPEN_RGB = { r = 0x25, g = 0x83, b = 0x96 }

-- ==================== 工具 ====================
-- getScreenPixel 返回 BBGGRR 十进制(见 core/minimap.lua 结论7)
local function trueRGB(v)
    local r, g, b = colorToRGB(v)
    return b, g, r
end

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
            return lum, (mx - mn)
        end
    end
    return nil
end

-- 屏幕角(0=右, 90=下, 顺时针) → 罗盘方位(0=上/北, 顺时针)
function _M.screenToCompass(a)
    local c = (a + 90) % 360
    if c < 0 then c = c + 360 end
    return c
end

-- 方位差(-180..180)
function _M.diffTo180(d)
    d = d % 360
    if d > 180 then d = d - 360 end
    return d
end

-- 方位 → 中文(8 方位)
local DIRS = { "北", "东北", "东", "东南", "南", "西南", "西", "西北" }
function _M.compassText(bearing)
    local i = math.floor(((bearing or 0) % 360) / 45 + 0.5) % 8 + 1
    return DIRS[i]
end

-- ==================== 极坐标剖面(核心) ====================
-- 预计算: 以 (cx,cy) 为极点、半径 [rMin,rMax] 内每个像素的(数组偏移, 角度桶1..360)
local _plan, _planKey
local function ensurePlan(w, rx1, ry1, cx, cy, rmin, rmax)
    local key = table.concat({ w, rx1, ry1, cx, cy, rmin, rmax }, ",")
    if _plan and _planKey == key then return end
    local rmin2, rmax2 = rmin * rmin, rmax * rmax
    local plan = {}
    for yy = cy - rmax, cy + rmax do
        local rowBase = (yy - ry1) * w
        local dy = yy - cy
        for xx = cx - rmax, cx + rmax do
            local dx = xx - cx
            local d2 = dx * dx + dy * dy
            if d2 >= rmin2 and d2 <= rmax2 then
                local deg = math.deg(math.atan2(dy, dx))
                if deg < 0 then deg = deg + 360 end
                plan[#plan + 1] = { off = rowBase + (xx - rx1 + 1), bin = math.floor(deg) % 360 + 1 }
            end
        end
    end
    _plan, _planKey = plan, key
end

-- 以 (cx,cy) 为极点统计角度剖面 → 锥中心方向
local function profileAt(w, arr, rx1, ry1, cx, cy, rmin, rmax)
    local cfg = _M.CFG
    ensurePlan(w, rx1, ry1, cx, cy, rmin, rmax)
    local prof = {}
    for i = 1, 360 do prof[i] = 0 end
    local n = 0
    for i = 1, #_plan do
        local p = _plan[i]
        local r, g, b = trueRGB(arr[p.off])
        if r then
            local lum, sat = isCone(r, g, b, cfg)
            if lum and sat < cfg.satMax then
                prof[p.bin] = prof[p.bin] + (lum - cfg.lumMin)
                n = n + 1
            end
        end
    end
    if n < 15 then return nil, "no_cone", n end

    local k, half = cfg.smoothK, math.floor(cfg.smoothK / 2)
    local sm = {}
    for i = 1, 360 do
        local s = 0
        for j = -half, half do
            s = s + prof[(i - 1 + j) % 360 + 1]
        end
        sm[i] = s / k
    end
    local sorted = {}
    for i = 1, 360 do sorted[i] = sm[i] end
    table.sort(sorted)
    local base = (sorted[180] + sorted[181]) / 2

    local vx, vy, tot = 0, 0, 0
    local energies = {}
    for i = 1, 360 do
        local v = sm[i] - base
        if v > 0 then
            local a = math.rad(i - 1)
            vx = vx + v * math.cos(a)
            vy = vy + v * math.sin(a)
            tot = tot + v
        end
        energies[i] = v > 0 and v or 0
    end
    if tot <= 0 then return nil, "no_cone", n end
    local screen = math.deg(math.atan2(vy, vx))
    if screen < 0 then screen = screen + 360 end

    table.sort(energies, function(a, b) return a > b end)
    local top, all = 0, 0
    for i = 1, 360 do
        all = all + energies[i]
        if i <= cfg.bandBins then top = top + energies[i] end
    end
    return {
        bearing = _M.screenToCompass(screen),
        screen = screen,
        conf = all > 0 and top / all or 0,
        n = n,
        profile = sm,
    }, nil, n
end

-- ==================== ① 小地图模式 ====================
-- center: 可选 {x,y} 覆盖默认极点
function _M.detect(center)
    local cfg = _M.CFG
    local rx1, ry1, rx2, ry2 = _M.REGION.x1, _M.REGION.y1, _M.REGION.x2, _M.REGION.y2
    local w, h, arr = getScreenPixel(rx1, ry1, rx2, ry2)
    if not w or w <= 0 then return nil, "no_shot" end
    local cx = center and center.x or _M.CENTER.x
    local cy = center and center.y or _M.CENTER.y
    local r, err = profileAt(w, arr, rx1, ry1, cx, cy, cfg.rMin, cfg.rMax)
    if not r then return nil, err end
    r.center = { x = cx, y = cy }
    r.x, r.y = cx, cy
    r.mode = "mini"
    return r
end

-- ==================== ② 大地图模式 ====================
local function inExclude(x, y)
    for _, e in ipairs(_M.BM_EXCLUDE) do
        if x >= e.x1 and x <= e.x2 and y >= e.y1 and y <= e.y2 then return true end
    end
    return false
end

-- 环评分: 中心 (cx,cy) 处以 r∈[5,11] 画圆, 圆上白点占比 - 内部白点占比
-- 返回 最佳半径, 评分(0..1)
local function ringScore(arr, w, rx1, ry1, cx, cy)
    local bestR, bestS = 0, 0
    for rr = 5, 11 do
        local hit, n = 0, 0
        for j = 0, 23 do
            local a = j * math.pi / 12
            local x = math.floor(cx + rr * math.cos(a) + 0.5)
            local y = math.floor(cy + rr * math.sin(a) + 0.5)
            local r, g, b = trueRGB(arr[(y - ry1) * w + (x - rx1 + 1)])
            if r then
                n = n + 1
                if r > 205 and g > 205 and b > 205 then hit = hit + 1 end
            end
        end
        local inner, ihit = 0, 0
        local ir = math.max(1, rr - 3)
        for j = 0, 7 do
            local a = j * math.pi / 4
            local x = math.floor(cx + ir * math.cos(a) + 0.5)
            local y = math.floor(cy + ir * math.sin(a) + 0.5)
            local r, g, b = trueRGB(arr[(y - ry1) * w + (x - rx1 + 1)])
            if r then
                inner = inner + 1
                if r > 205 and g > 205 and b > 205 then ihit = ihit + 1 end
            end
        end
        local s = n > 0 and (hit / n) or 0
        if inner > 0 then s = s - 0.8 * (ihit / inner) end
        if s > bestS then bestS, bestR = s, rr end
    end
    return bestR, bestS
end

-- 环心细化(全分辨率): 在半径 rad 内取白像素质心
local function refineRing(arr, w, rx1, ry1, cx, cy, rad)
    local sx, sy, n = 0, 0, 0
    local r2 = rad * rad
    for y = cy - rad, cy + rad do
        for x = cx - rad, cx + rad do
            local dx, dy = x - cx, y - cy
            if dx * dx + dy * dy <= r2 then
                local r, g, b = trueRGB(arr[(y - ry1) * w + (x - rx1 + 1)])
                if r and r > 205 and g > 205 and b > 205 then
                    sx = sx + x; sy = sy + y; n = n + 1
                end
            end
        end
    end
    if n >= 6 then return sx / n, sy / n, n end
    return cx, cy, 0
end

-- 单区域: 先找玩家白环(圆环状), 再在其周围做极坐标剖面测锥体方向
-- 返回 { x, y(玩家屏幕坐标), bearing, screen, conf, n, ringR, ringS, score } 或 nil, err
local function detectInRegion(x1, y1, x2, y2)
    local cfg = _M.BM_CFG
    local w, h, arr = getScreenPixel(x1, y1, x2, y2)
    if not w or w <= 0 then return nil, "no_shot" end

    -- 1) 粗扫白色像素并按 8px 单元聚类(找环候选)
    local step, cell = cfg.step, cfg.cell
    local nx = math.floor((x2 - x1) / cell) + 1
    local grid = {}
    for yy = y1, y2, step do
        local base = (yy - y1) * w
        for xx = x1, x2, step do
            if not inExclude(xx, yy) then
                local r, g, b = trueRGB(arr[base + (xx - x1 + 1)])
                if r and r > 218 and g > 218 and b > 218 then
                    local gx, gy = math.floor((xx - x1) / cell), math.floor((yy - y1) / cell)
                    local k = gy * nx + gx
                    local c = grid[k]
                    if not c then
                        c = { n = 0, sx = 0, sy = 0, bxs = 9999, bxe = 0, bys = 9999, bye = 0 }
                        grid[k] = c
                    end
                    c.n = c.n + 1
                    c.sx = c.sx + xx
                    c.sy = c.sy + yy
                    if xx < c.bxs then c.bxs = xx end
                    if xx > c.bxe then c.bxe = xx end
                    if yy < c.bys then c.bys = yy end
                    if yy > c.bye then c.bye = yy end
                end
            end
        end
    end
    local seen, blobs = {}, {}
    for k, c in pairs(grid) do
        if not seen[k] and c.n >= 2 then
            local q = { k }
            seen[k] = true
            local cl = { n = 0, sx = 0, sy = 0, bxs = 9999, bxe = 0, bys = 9999, bye = 0 }
            local qh = 1
            while qh <= #q do
                local kk = q[qh]; qh = qh + 1
                local cc = grid[kk]
                cl.n = cl.n + cc.n; cl.sx = cl.sx + cc.sx; cl.sy = cl.sy + cc.sy
                if cc.bxs < cl.bxs then cl.bxs = cc.bxs end
                if cc.bxe > cl.bxe then cl.bxe = cc.bxe end
                if cc.bys < cl.bys then cl.bys = cc.bys end
                if cc.bye > cl.bye then cl.bye = cc.bye end
                local gx, gy = kk % nx, math.floor(kk / nx)
                for ox = -1, 1 do
                    for oy = -1, 1 do
                        local nk = (gy + oy) * nx + (gx + ox)
                        local nc = grid[nk]
                        if nc and not seen[nk] and nc.n >= 2 then
                            seen[nk] = true
                            q[#q + 1] = nk
                        end
                    end
                end
            end
            blobs[#blobs + 1] = cl
        end
    end

    -- 2) 白团尺寸过滤 → 环候选(圆环直径约 16~26px)
    local rings = {}
    for _, cl in ipairs(blobs) do
        local bw, bh = cl.bxe - cl.bxs, cl.bye - cl.bys
        if cl.n >= 12 and bw >= 10 and bw <= 34 and bh >= 10 and bh <= 34 then
            local cx, cy = cl.sx / cl.n, cl.sy / cl.n
            local rr, rs = ringScore(arr, w, x1, y1, math.floor(cx), math.floor(cy))
            if rs >= 0.55 then
                rings[#rings + 1] = { x = cx, y = cy, r = rr, s = rs, n = cl.n }
            end
        end
    end
    if #rings == 0 then return nil, "no_ring" end
    table.sort(rings, function(a, b) return a.s > b.s end)

    -- 3) 对环候选做剖面, 取"环评分 + 锥体集中度"最佳者
    local best
    for i = 1, math.min(#rings, 6) do
        local rg = rings[i]
        -- 环心细化(全分辨率质心) → 提高测角精度
        local fx, fy, fn = refineRing(arr, w, x1, y1, math.floor(rg.x), math.floor(rg.y), rg.r + 3)
        local pr = profileAt(w, arr, x1, y1, math.floor(fx), math.floor(fy), cfg.rMin, cfg.rMax)
        if pr and pr.n >= 40 and pr.conf >= 0.80 then
            local score = pr.conf * 100 + rg.s * 20
            if not best or score > best.score then
                best = { x = fx, y = fy, screen = pr.screen, bearing = pr.bearing,
                         conf = pr.conf, n = pr.n, ringR = rg.r, ringS = rg.s,
                         ringN = fn, score = score }
            end
        end
    end
    if not best then
        -- 退化: 用环评分最高的位置, 只报位置(方向交给调用方判断)
        local rg = rings[1]
        return { x = rg.x, y = rg.y, bearing = nil, conf = 0, n = 0,
                 ringR = rg.r, ringS = rg.s, score = rg.s * 20 }, "weak_cone"
    end
    return best
end

-- 搜索区域: ① 展开的大地图面板; ② 常规小地图面板(副本/竞技场里标记会偏离中心)
_M.BM_SCAN = {
    { 300, 225, 905, 520 },
    { 1088, 0, 1279, 199 },
}

-- 非固定标记界面: 在多个区域内搜索白环 + 锥体
function _M.detectBigMap()
    local best, lastErr
    for _, r in ipairs(_M.BM_SCAN) do
        local res, err = detectInRegion(r[1], r[2], r[3], r[4])
        if res then
            res.mode = "big"
            if not best or (res.score or 0) > (best.score or 0) then best = res end
        else
            lastErr = err
        end
    end
    if not best then return nil, lastErr or "no_ring" end
    return best
end

-- 固定中心处是否确实有玩家白环(防止副本等界面标记不在中心时误判)
function _M.centerRingOk()
    local rx1, ry1 = _M.REGION.x1, _M.REGION.y1
    local rx2, ry2 = _M.REGION.x2, _M.REGION.y2
    local w, h, arr = getScreenPixel(rx1, ry1, rx2, ry2)
    if not w or w <= 0 then return false, 0 end
    local r, s = ringScore(arr, w, rx1, ry1, _M.CENTER.x, _M.CENTER.y)
    return s >= 0.5, s
end

-- 自动模式: 先试固定中心(常规小地图, 且中心确有白环), 否则全区域搜索(大地图/副本/竞技场)
function _M.detectAuto()
    local r = _M.detect()
    if r and r.conf >= _M.VOTE.minConf and (r.n or 0) >= 40 then
        if _M.centerRingOk() then return r end
    end
    local b, err = _M.detectBigMap()
    if b then return b end
    return nil, err or (r and "center_mismatch" or "no_result")
end

-- 自动模式 + 多帧投票
function _M.detectAutoStable(n, opts)
    opts = opts or {}
    n = n or _M.VOTE.frames
    local interval = opts.intervalMs or _M.VOTE.intervalMs
    local items, lastErr, miniN, bigN = {}, nil, 0, 0
    for i = 1, n do
        local it, err = _M.detectAuto()
        lastErr = err or lastErr
        items[i] = it
        if it and it.mode == "mini" then miniN = miniN + 1
        elseif it and it.mode == "big" then bigN = bigN + 1 end
        if i < n then sleep(interval) end
    end
    local res, verr = _M.voteResults(items, opts)
    if not res then return nil, verr or lastErr end
    res.mode = miniN >= bigN and "mini" or "big"
    res.miniN, res.bigN = miniN, bigN
    return res
end

-- ==================== ③ 多帧投票 + conf 门限 ====================
-- 把同一目标的多次检测结果投票: 先按 conf 门限过滤, 再按角度(和位置)聚类,
-- 取最大簇的加权圆均值。用于压掉偶发的 10°+ 误读。
-- items: { detect()/detectBigMap() 的返回 或 nil, ... }
-- opts: { minConf, tol, minVotes, posTol, allowSingle }
-- 返回 汇总结果, err; 汇总结果 = { bearing, screen, conf, spread, votes, agree, n, x, y }
function _M.voteResults(items, opts)
    opts = opts or {}
    local V = _M.VOTE
    local minConf = opts.minConf or V.minConf
    local tol = opts.tol or V.tol
    local minVotes = opts.minVotes or V.minVotes
    local posTol = opts.posTol or V.posTol

    local valid = {}
    for i = 1, #items do
        local it = items[i]
        if it and it.bearing and (it.conf or 0) >= minConf then
            valid[#valid + 1] = it
        end
    end
    if #valid == 0 then return nil, "no_valid" end
    if #valid < minVotes then
        if opts.allowSingle then
            local it = valid[1]
            return { bearing = it.bearing, screen = it.screen, conf = it.conf, n = it.n,
                     x = it.x, y = it.y, votes = 1, agree = 1, spread = 0, single = true }
        end
        return nil, "low_votes"
    end

    -- 以每个样本为种子聚类(角度差<=tol 且 大地图位置差<=posTol)
    local bestSet, bestN = nil, 0
    for i = 1, #valid do
        local s = { valid[i] }
        for j = 1, #valid do
            if j ~= i then
                local d = math.abs(_M.diffTo180(valid[j].bearing - valid[i].bearing))
                local okPos = true
                if valid[i].x and valid[j].x then
                    local dx, dy = valid[j].x - valid[i].x, valid[j].y - valid[i].y
                    okPos = (dx * dx + dy * dy) <= posTol * posTol
                end
                if d <= tol and okPos then s[#s + 1] = valid[j] end
            end
        end
        if #s > bestN then bestN, bestSet = #s, s end
    end
    -- 簇内票数仍不足(读数互相矛盾) → 不输出
    if bestN < minVotes then
        if opts.allowSingle then
            local it = valid[1]
            return { bearing = it.bearing, screen = it.screen, conf = it.conf, n = it.n,
                     x = it.x, y = it.y, votes = 1, agree = 1, spread = 0, single = true }
        end
        return nil, "low_agree"
    end

    -- 簇内加权圆均值
    local vx, vy, ws = 0, 0, 0
    local confS, nS, sx, sy, wS = 0, 0, 0, 0, 0
    for _, it in ipairs(bestSet) do
        local w = it.conf or 0.5
        local a = math.rad(it.bearing)
        vx = vx + w * math.cos(a)
        vy = vy + w * math.sin(a)
        ws = ws + w
        confS = confS + (it.conf or 0)
        nS = nS + (it.n or 0)
        if it.x and it.y then
            sx = sx + it.x * w
            sy = sy + it.y * w
            wS = wS + w
        end
    end
    local bearing = math.deg(math.atan2(vy, vx)) % 360
    local spread = 0
    for _, it in ipairs(bestSet) do
        local d = math.abs(_M.diffTo180(it.bearing - bearing))
        if d > spread then spread = d end
    end
    return {
        bearing = bearing,
        screen = (bearing - 90) % 360,
        conf = confS / #bestSet,
        spread = spread,
        votes = #bestSet,
        agree = #bestSet / #valid,
        n = math.floor(nS / #bestSet),
        x = wS > 0 and sx / wS or nil,
        y = wS > 0 and sy / wS or nil,
    }
end

-- 小地图: 连续采样 n 帧后投票
function _M.detectStable(n, opts)
    opts = opts or {}
    n = n or _M.VOTE.frames
    local interval = opts.intervalMs or _M.VOTE.intervalMs
    local items, lastErr = {}, nil
    for i = 1, n do
        local it, err = _M.detect(opts.center)
        lastErr = err or lastErr
        items[i] = it
        if i < n then sleep(interval) end
    end
    local r, verr = _M.voteResults(items, opts)
    if not r then return nil, verr or lastErr end
    return r
end

-- 大地图: 连续采样 n 帧后投票
function _M.detectBigMapStable(n, opts)
    opts = opts or {}
    n = n or _M.VOTE.frames
    local interval = opts.intervalMs or _M.VOTE.intervalMs
    local items, lastErr = {}, nil
    for i = 1, n do
        local it, err = _M.detectBigMap()
        lastErr = err or lastErr
        items[i] = it
        if i < n then sleep(interval) end
    end
    local r, verr = _M.voteResults(items, opts)
    if not r then return nil, verr or lastErr end
    return r
end

-- ==================== ④ 界面判别 ====================
-- 大地图是否展开: 右上角被大面积统一的青蓝色 CLOSE 按钮占据
-- 返回 bool, 命中率
function _M.isBigMapOpen()
    local c = _M.BM_OPEN_RGB
    local tot, hit = 0, 0
    for y = 45, 165, 30 do
        for x = 1145, 1265, 30 do
            local h = getPixelColor(x, y)
            if h then
                local rs = string.sub(h, 3, 4)
                local gs = string.sub(h, 5, 6)
                local bs = string.sub(h, 7, 8)
                local r = tonumber(rs, 16)
                local g = tonumber(gs, 16)
                local b = tonumber(bs, 16)
                tot = tot + 1
                if r and g and b and math.abs(r - c.r) <= 28
                   and math.abs(g - c.g) <= 28 and math.abs(b - c.b) <= 28 then
                    hit = hit + 1
                end
            end
        end
    end
    return tot > 0 and (hit / tot) >= 0.6, (tot > 0 and hit / tot or 0)
end

return _M
