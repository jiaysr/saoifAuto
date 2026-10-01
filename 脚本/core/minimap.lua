-- 脚本/core/minimap.lua
-- SAOIF 小地图识别模块
-- ==================== 探索结论（2026-09，Pixel 4 / 1280x720 横屏） ====================
-- 1) 小地图固定于右上角：内容区 (1094,12)-(1269,188)，中心约 (1181,100)，四周为青色双线边框。
-- 2) 地形为「北向上」固定朝向：旋转镜头地形不转，仅有视野锥旋转（已实测 69° 旋转地形不变）。
-- 3) 玩家标记 = 白色圆环，恒定位于小地图中心；地图内容在标记下方滚动。
-- 4) 视野锥 = 从圆环出发的淡黄绿色扇形（还有一条反向白色短尾），质心方向即镜头朝向。
-- 5) 地图配色：深蓝=水域/底色，青绿=陆地，亮青=边框；其余明显颜色（白/黄/红/绿）多为图标。
-- 6) 水域等空旷区几乎无纹理（±3 级），模板匹配不可靠；图标+朝向识别可靠。
-- 7) getScreenPixel 返回数组为 BBGGRR 十进制：colorToRGB 后需交换 r/b 才是真实 RGB。
-- 8) 拖拽镜头：向左拖 270px ≈ 朝向 -69°（约 3.9px/度），原点默认 (700,150)（空地，避免误触按钮）。
--
-- 用法：local mm = require("core.minimap"); local r = mm.update()
-- r = nil（未检测到小地图）或
-- r = { yaw=罗盘朝向(0=上/北,顺时针), coneAng=屏幕角(-90=上), yawN=锥体亮像素数,
--       markerN=白色标记像素数, blobs={ {cx,cy,n,cls,r,g,b,bearing,dist}, ... } }

local _M = {}

-- 模板匹配兜底（亮色地形/亮团粘连导致环-锥法失败时使用）
local okTpl, tpl = pcall(require, "core.templates")
if not okTpl then tpl = nil end

-- 小地图整区（含边框）与内容区
_M.REGION = { x1 = 1088, y1 = 0, x2 = 1279, y2 = 199 }
_M.INNER = { x1 = 1094, y1 = 12, x2 = 1269, y2 = 188 }
_M.CENTER = { x = 1181, y = 100 }

-- 可调参数
_M.CFG = {
    coneMinLum = 145,   -- 视野锥亮度阈值
    coneRMin = 6,       -- 视野锥搜索内半径（避开圆环）
    coneRMax = 46,      -- 视野锥搜索外半径
    markerBox = 16,     -- 标记搜索半宽（中心附近）
    blobStep = 2,       -- 图标扫描步长
    blobMinPx = 12,     -- 图标最小像素数
    blobCell = 8,       -- 聚类单元大小
    blobCenterExcl = 52, -- 中心排除半径（视野锥/标记区不参与图标检测）
    turnPxPerDeg = 2.9, -- 拖拽像素/度（横屏，标称值；闭环迭代会修正）
    turnStepPx = 250,   -- 单次拖拽上限(px)，过大易受惯性影响
    turnOrigin = { x = 700, y = 150 }, -- 拖拽起点（空地）
    turnMaxPx = 520,    -- 单次拖拽最大距离
}

-- 数组像素值 → 真实 RGB（见结论 7）
local function trueRGB(v)
    local r, g, b = colorToRGB(v)
    return b, g, r
end

-- 屏幕角(-180..180, -90=上) → 罗盘角(0=上/北, 顺时针)
local function screenToCompass(ang)
    local c = (ang + 90) % 360
    if c < 0 then c = c + 360 end
    return c
end

function _M.screenAngle(dx, dy)
    if dx == 0 and dy == 0 then return nil end
    return math.deg(math.atan2(dy, dx))
end

-- 由中心到 (dx,dy) 的罗盘方位（0=上/北, 顺时针）
function _M.bearing(dx, dy)
    local a = _M.screenAngle(dx, dy)
    return a and screenToCompass(a) or 0
end

-- 角度差（-180..180）
function _M.diffTo180(d)
    d = d % 360
    if d > 180 then d = d - 360 end
    return d
end

-- ==================== 内部：视野锥角度 ====================
-- excludeWhite: 是否剔除纯白像素（圆环/尾巴），只留淡色锥体
local function coneAngle(arr, w)
    local cx, cy = _M.CENTER.x, _M.CENTER.y
    local rx1, ry1 = _M.REGION.x1, _M.REGION.y1
    local cfg = _M.CFG
    local rmin, rmax = cfg.coneRMin, cfg.coneRMax
    local rmin2, rmax2 = rmin * rmin, rmax * rmax
    local sx, sy, sw, n = 0, 0, 0, 0
    local sx2, sy2, sw2, n2 = 0, 0, 0, 0
    for yy = cy - rmax, cy + rmax do
        local rowBase = (yy - ry1) * w
        local dy = yy - cy
        for xx = cx - rmax, cx + rmax do
            local dx = xx - cx
            local d2 = dx * dx + dy * dy
            if d2 >= rmin2 and d2 <= rmax2 then
                local r, g, b = trueRGB(arr[rowBase + (xx - rx1 + 1)])
                local lum = (r + g + b) / 3
                if lum > cfg.coneMinLum then
                    local wt = lum - cfg.coneMinLum
                    sx = sx + dx * wt; sy = sy + dy * wt; sw = sw + wt; n = n + 1
                    if not (r > 240 and g > 240 and b > 240) then
                        sx2 = sx2 + dx * wt; sy2 = sy2 + dy * wt; sw2 = sw2 + wt; n2 = n2 + 1
                    end
                end
            end
        end
    end
    local ang1 = sw > 0 and math.deg(math.atan2(sy / sw, sx / sw)) or nil
    local ang2 = sw2 > 0 and math.deg(math.atan2(sy2 / sw2, sx2 / sw2)) or nil
    return ang1, n, ang2, n2
end

-- ==================== 内部：白色标记 ====================
local function findMarker(arr, w)
    local cfg = _M.CFG
    local cx, cy = _M.CENTER.x, _M.CENTER.y
    local rx1, ry1 = _M.REGION.x1, _M.REGION.y1
    local sx, sy, n = 0, 0, 0
    local bx1, bx2, by1, by2 = 9999, 0, 9999, 0
    for yy = cy - cfg.markerBox, cy + cfg.markerBox do
        local rowBase = (yy - ry1) * w
        for xx = cx - cfg.markerBox, cx + cfg.markerBox do
            local r, g, b = trueRGB(arr[rowBase + (xx - rx1 + 1)])
            if r > 235 and g > 235 and b > 235 then
                n = n + 1; sx = sx + xx; sy = sy + yy
                if xx < bx1 then bx1 = xx end
                if xx > bx2 then bx2 = xx end
                if yy < by1 then by1 = yy end
                if yy > by2 then by2 = yy end
            end
        end
    end
    if n == 0 then return nil end
    return { n = n, x = sx / n, y = sy / n, w = bx2 - bx1, h = by2 - by1 }
end

-- ==================== 内部：图标（颜色团块） ====================
-- 分类：white/yellow/red/green；地形（蓝青灰系）忽略
local function classifyBlob(r, g, b)
    if r > 225 and g > 225 and b > 225 then return "white" end
    -- 淡色（视野锥/半透明覆盖）不算图标
    if r > 150 and g > 150 and b > 140 and (math.max(r, g, b) - math.min(r, g, b)) < 80 then return nil end
    if b >= g * 0.8 and (b - r) > 25 then return nil end          -- 蓝/青系地形
    if (g - b) > 40 and (g - r) > 40 then return "green" end
    if (r - b) > 30 and r > 130 then
        if g > 150 then return "yellow" end
        return "red"
    end
    if r > 150 and g > 150 and b > 140 then return nil end          -- 灰白边框
    return nil
end

local function findBlobs(arr, w, excl)
    local cfg = _M.CFG
    excl = excl or cfg.blobCenterExcl
    local step = cfg.blobStep
    local cell = cfg.blobCell
    local x1, y1 = _M.INNER.x1, _M.INNER.y1
    local x2, y2 = _M.INNER.x2, _M.INNER.y2
    local cx, cy = _M.CENTER.x, _M.CENTER.y
    -- 网格单元：nx x ny
    local nx = math.floor((x2 - x1) / cell) + 1
    local ny = math.floor((y2 - y1) / cell) + 1
    local grid = {}
    for yy = y1, y2, step do
        local rowBase = (yy - y1) * w
        for xx = x1, x2, step do
            local r, g, b = trueRGB(arr[rowBase + (xx - x1 + 1)])
            local cls = classifyBlob(r, g, b)
            if cls then
                -- 排除中心视野区（锥体/标记）
                local dx, dy = xx - cx, yy - cy
                if dx * dx + dy * dy > excl * excl then
                    -- 排除右下角 "+" 按钮区
                    if not (xx > 1240 and yy > 176) then
                        local gx, gy = math.floor((xx - x1) / cell), math.floor((yy - y1) / cell)
                        local k = gy * nx + gx
                        local c = grid[k]
                        if not c then
                            c = { n = 0, sx = 0, sy = 0, cls = cls, clsN = 0 }
                            grid[k] = c
                        end
                        c.n = c.n + 1; c.sx = c.sx + xx; c.sy = c.sy + yy
                    end
                end
            end
        end
    end
    -- 合并相邻单元（BFS）
    local visited = {}
    local out = {}
    for k, c in pairs(grid) do
        if not visited[k] and c.n >= 2 then
            local queue = { k }
            visited[k] = true
            local cl = { n = 0, sx = 0, sy = 0 }
            local qh = 1
            while qh <= #queue do
                local kk = queue[qh]; qh = qh + 1
                local cc = grid[kk]
                cl.n = cl.n + cc.n; cl.sx = cl.sx + cc.sx; cl.sy = cl.sy + cc.sy
                local gx, gy = kk % nx, math.floor(kk / nx)
                for ox = -1, 1 do
                    for oy = -1, 1 do
                        local nk = (gy + oy) * nx + (gx + ox)
                        local nc = grid[nk]
                        if nc and not visited[nk] and nc.n >= 2 then
                            visited[nk] = true
                            queue[#queue + 1] = nk
                        end
                    end
                end
            end
            if cl.n >= cfg.blobMinPx then
                local mx, my = cl.sx / cl.n, cl.sy / cl.n
                -- 取合并簇内主色（用最近单元颜色近似）
                local cls = c.cls
                out[#out + 1] = {
                    x = mx, y = my, n = cl.n, cls = cls,
                    dx = mx - cx, dy = my - cy,
                    bearing = _M.bearing(mx - cx, my - cy),
                    dist = math.sqrt((mx - cx) * (mx - cx) + (my - cy) * (my - cy)),
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.n > b.n end)
    return out
end

-- 锥体矢量：以 (cx,cy) 为中心，亮(非纯白)像素的加权方向
-- 返回 罗盘方位角, 像素数, 加权距离(不对称度)
local function coneVectorAt(arr, w, cx, cy)
    local rmin, rmax = 8, 40
    local sx, sy, sw, n = 0, 0, 0, 0
    local bx1 = math.max(_M.INNER.x1, cx - rmax)
    local bx2 = math.min(_M.INNER.x2, cx + rmax)
    local by1 = math.max(_M.INNER.y1, cy - rmax)
    local by2 = math.min(_M.INNER.y2, cy + rmax)
    for yy = by1, by2 do
        local base = (yy - _M.INNER.y1) * w
        local dy = yy - cy
        for xx = bx1, bx2 do
            local dx = xx - cx
            local d2 = dx * dx + dy * dy
            if d2 >= rmin * rmin and d2 <= rmax * rmax then
                local r, g, b = trueRGB(arr[base + (xx - _M.INNER.x1 + 1)])
                if r then
                    local lum = (r + g + b) / 3
                    local mx = math.max(r, g, b)
                    local mn = math.min(r, g, b)
                    if lum > 145 and not (mn > 170 and (mx - mn) < 60) then
                        local wt = lum - 145
                        sx = sx + dx * wt; sy = sy + dy * wt; sw = sw + wt; n = n + 1
                    end
                end
            end
        end
    end
    if sw == 0 then return nil, 0, 0 end
    return _M.bearing(sx / sw, sy / sw), n, math.sqrt(sx * sx + sy * sy) / sw
end

-- ==================== 对外：更新一次 ====================
-- 2026-09 修正：原先的「中心亮像素质心」法在部分场景（小镇）会把锥体当纯白剔除，
-- 导致测出反向 180°。现统一改用「环(白)→锥(彩)矢量」法（findMarkerEx），
-- 标记不在中心也适用；以地图中心作为搜索提示加速。
function _M.update()
    local rx1, ry1, rx2, ry2 = _M.REGION.x1, _M.REGION.y1, _M.REGION.x2, _M.REGION.y2
    local w, h, arr = getScreenPixel(rx1, ry1, rx2, ry2)
    if not w or w <= 0 then return nil end
    local marker = _M.findMarkerEx(arr, w, nil) -- 全图搜索（ROI 提示会误选，见 2026-09-28 实测）
    if not marker and tpl then
        -- 兜底：模板匹配玩家标记钉（2026-09-28 副本亮色地形实测）
        local mk = tpl.match("marker", { _M.INNER.x1, _M.INNER.y1, _M.INNER.x2, _M.INNER.y2 }, 0.5)
        if mk then
            local ang, cn, dist = coneVectorAt(arr, w, mk.x, mk.y)
            if ang then
                marker = { x = mk.x, y = mk.y, ang = ang, wn = 0, cn = cn, dist = dist, viaTpl = true, sim = mk.sim }
            end
        end
    end
    if not marker then
        return { ok = false, reason = "no_marker" }
    end
    local blobs = findBlobs(arr, w)
    local screenAng = (marker.ang - 90) % 360
    if screenAng > 180 then screenAng = screenAng - 360 end
    return {
        ok = true,
        yaw = marker.ang,
        compass = marker.ang,
        coneAng = screenAng,
        coneN = marker.cn,
        markerN = marker.wn,
        markerX = marker.x,
        markerY = marker.y,
        markerW = marker.wn,
        markerH = marker.cn,
        blobs = blobs,
    }
end

-- ==================== 对外：镜头转向（拖拽，闭环迭代） ====================
-- 将镜头转到目标罗盘角度（0=上/北，顺时针）。
-- 单次拖拽的"像素→角度"存在非线性与惯性，因此采用 测量→拖拽→复测 的闭环，
-- 直到误差 <= tolerance 或达到最大次数。返回 最终误差, 说明
function _M.turnTo(targetCompass, tolerance)
    tolerance = tolerance or 3
    local cfg = _M.CFG
    local lastErr
    for _ = 1, 5 do
        local r = _M.update()
        if not r or not r.ok or not r.yaw then return lastErr, "no_minimap" end
        local diff = _M.diffTo180(targetCompass - r.yaw)
        lastErr = diff
        if math.abs(diff) <= tolerance then return diff, "ok" end
        local px = diff * cfg.turnPxPerDeg
        if px > cfg.turnStepPx then px = cfg.turnStepPx end
        if px < -cfg.turnStepPx then px = -cfg.turnStepPx end
        local x0, y0 = cfg.turnOrigin.x, cfg.turnOrigin.y
        swipe(x0, y0, x0 + px, y0, math.min(500, math.max(120, math.abs(px) * 1.6)))
        sleep(280)
    end
    return lastErr, "max_attempts"
end

-- ==================== 对外：调试扫描（粗字符图，真实 RGB） ====================
function _M.debugScan(step)
    step = step or 6
    local rx1, ry1, rx2, ry2 = _M.REGION.x1, _M.REGION.y1, _M.REGION.x2, _M.REGION.y2
    local w, h, arr = getScreenPixel(rx1, ry1, rx2, ry2)
    if not w or w <= 0 then return { "取像失败" } end
    local lines = {}
    for yy = ry1, ry2 - 1, step do
        local row = {}
        for xx = rx1, rx2 - 1, step do
            local r, g, b = trueRGB(arr[(yy - ry1) * w + (xx - rx1 + 1)])
            local cls = classifyBlob(r, g, b)
            local ch
            if r > 235 and g > 235 and b > 235 then
                ch = "W"
            elseif cls == "yellow" then ch = "Y"
            elseif cls == "red" then ch = "R"
            elseif cls == "green" then ch = "G"
            elseif b >= g * 0.8 and (b - r) > 25 then
                ch = (g > 185 and b > 165) and "T" or "~"
            elseif r > 150 and g > 150 then ch = "-"
            else ch = "?" end
            row[#row + 1] = ch
        end
        lines[#lines + 1] = table.concat(row)
    end
    return lines
end

-- ==================== 对外：通用标记定位（环+锥，副本/竞技场可用） ====================
-- 标记 = 亮色圆环(近白) + 视线锥(淡色)。用「亮度掩膜 + 环/锥双团」判据定位，
-- 不假设标记在中心（副本/竞技场里标记会偏离中心）。
-- hint: 上次标记位置（可选），用于缩小搜索范围加速。
-- 返回 { x, y, ang(锥朝向,罗盘), score, wn, cn, dist } 或 nil
local function ringConeScan(arr, w, rx1, ry1, rx2, ry2)
    -- 版本 A（2026-09-28 验证通过：小镇读数 266.9°=西 ✓，竞技场瞄准闭环 ✓）
    -- 亮团(亮度>150, 非红)聚类；团内分「白(近白低饱和)=环」「其余亮=锥」；
    -- 环心→锥心 方向即镜头朝向。大团块(跨度>64)跳过，防止与地图图标粘连误检。
    local cell = 4
    local nx = math.floor((rx2 - rx1) / cell) + 1
    local grid = {}
    for yy = ry1, ry2 do
        local base = (yy - _M.INNER.y1) * w
        for xx = rx1, rx2 do
            local r, g, b = trueRGB(arr[base + (xx - _M.INNER.x1 + 1)])
            if r then
                local lum = (r + g + b) / 3
                local mx = math.max(r, g, b)
                local mn = math.min(r, g, b)
                local isRed = (r - g) > 40 and (r - b) > 40
                if lum > 150 and not isRed then
                    local gx, gy = math.floor((xx - rx1) / cell), math.floor((yy - ry1) / cell)
                    local k = gy * nx + gx
                    local c = grid[k]
                    if not c then
                        c = { n = 0, sx = 0, sy = 0, wn = 0, wsx = 0, wsy = 0, cn = 0, csx = 0, csy = 0,
                              bx1 = 9999, bx2 = 0, by1 = 9999, by2 = 0 }
                        grid[k] = c
                    end
                    c.n = c.n + 1; c.sx = c.sx + xx; c.sy = c.sy + yy
                    if xx < c.bx1 then c.bx1 = xx end
                    if xx > c.bx2 then c.bx2 = xx end
                    if yy < c.by1 then c.by1 = yy end
                    if yy > c.by2 then c.by2 = yy end
                    if mn > 172 and (mx - mn) < 60 then
                        c.wn = c.wn + 1; c.wsx = c.wsx + xx; c.wsy = c.wsy + yy
                    else
                        c.cn = c.cn + 1; c.csx = c.csx + xx; c.csy = c.csy + yy
                    end
                end
            end
        end
    end
    local seen, out = {}, {}
    for k, c in pairs(grid) do
        if not seen[k] and c.n >= 3 then
            local q = { k }; seen[k] = true
            local cl = { n = 0, sx = 0, sy = 0, wn = 0, wsx = 0, wsy = 0, cn = 0, csx = 0, csy = 0,
                         bx1 = 9999, bx2 = 0, by1 = 9999, by2 = 0 }
            local qh = 1
            while qh <= #q do
                local kk = q[qh]; qh = qh + 1
                local cc = grid[kk]
                cl.n = cl.n + cc.n; cl.sx = cl.sx + cc.sx; cl.sy = cl.sy + cc.sy
                cl.wn = cl.wn + cc.wn; cl.wsx = cl.wsx + cc.wsx; cl.wsy = cl.wsy + cc.wsy
                cl.cn = cl.cn + cc.cn; cl.csx = cl.csx + cc.csx; cl.csy = cl.csy + cc.csy
                if cc.bx1 < cl.bx1 then cl.bx1 = cc.bx1 end
                if cc.bx2 > cl.bx2 then cl.bx2 = cc.bx2 end
                if cc.by1 < cl.by1 then cl.by1 = cc.by1 end
                if cc.by2 > cl.by2 then cl.by2 = cc.by2 end
                local gx, gy = kk % nx, math.floor(kk / nx)
                for ox = -1, 1 do for oy = -1, 1 do
                    local nk = (gy + oy) * nx + (gx + ox)
                    local nc = grid[nk]
                    if nc and not seen[nk] and nc.n >= 3 then seen[nk] = true; q[#q + 1] = nk end
                end end
            end
            out[#out + 1] = cl
        end
    end
    local best
    for _, cl in ipairs(out) do
        local spanW = cl.bx2 - cl.bx1
        local spanH = cl.by2 - cl.by1
        if spanW <= 64 and spanH <= 64 and cl.wn >= 15 and cl.cn >= 25 then
            local wx, wy = cl.wsx / cl.wn, cl.wsy / cl.wn
            local cx, cy = cl.csx / cl.cn, cl.csy / cl.cn
            local d = math.sqrt((cx - wx) ^ 2 + (cy - wy) ^ 2)
            if d >= 5 and d <= 34 then
                local score = cl.wn + cl.cn - d
                if not best or score > best.score then
                    best = { x = wx, y = wy, ang = _M.bearing(cx - wx, cy - wy),
                             score = score, wn = cl.wn, cn = cl.cn, dist = d }
                end
            end
        end
    end
    return best
end

function _M.findMarkerEx(arr, w, hint)
    local res
    if hint then
        local x1 = math.max(_M.INNER.x1, math.floor(hint.x) - 48)
        local y1 = math.max(_M.INNER.y1, math.floor(hint.y) - 48)
        local x2 = math.min(_M.INNER.x2, math.floor(hint.x) + 48)
        local y2 = math.min(_M.INNER.y2, math.floor(hint.y) + 48)
        res = ringConeScan(arr, w, x1, y1, x2, y2)
    end
    if not res then
        res = ringConeScan(arr, w, _M.INNER.x1, _M.INNER.y1, _M.INNER.x2, _M.INNER.y2)
    end
    return res
end

-- 一次取像：定位标记 + 图标团块（不排除中心，副本模式用）
function _M.updateEx(hint)
    local x1, y1, x2, y2 = _M.REGION.x1, _M.REGION.y1, _M.REGION.x2, _M.REGION.y2
    local w, h, arr = getScreenPixel(x1, y1, x2, y2)
    if not w or w <= 0 then return nil end
    local marker = _M.findMarkerEx(arr, w, hint)
    local blobs = findBlobs(arr, w, 0)
    return { ok = marker ~= nil, marker = marker, blobs = blobs }
end

-- 取指定颜色类最大的图标
function _M.pickBlob(blobs, cls)
    local best
    for _, b in ipairs(blobs or {}) do
        if b.cls == cls and (not best or b.n > best.n) then best = b end
    end
    return best
end

-- 闭环瞄准：把视线锥转向指定颜色的图标（red/yellow/white/green）
-- opts: { tolerance=4, maxIter=8, stepMs=400, onStep=function(i,diff,res) }
-- 返回 最终偏差, 说明, 最后结果
function _M.aimAt(cls, opts)
    opts = opts or {}
    local tol = opts.tolerance or 4
    local maxIter = opts.maxIter or 8
    local hint
    local lastDiff, lastRes
    local miss = 0
    for i = 1, maxIter do
        local r = _M.updateEx(hint)
        if r and r.marker then
            hint = r.marker
            lastRes = r
            local tgt = _M.pickBlob(r.blobs, cls)
            if tgt then
                local bearing = _M.bearing(tgt.x - r.marker.x, tgt.y - r.marker.y)
                local diff = _M.diffTo180(bearing - r.marker.ang)
                lastDiff = diff
                if opts.onStep then opts.onStep(i, diff, r, tgt) end
                if math.abs(diff) <= tol then return diff, "ok", r end
                local px = diff * _M.CFG.turnPxPerDeg
                if px > _M.CFG.turnStepPx then px = _M.CFG.turnStepPx end
                if px < -_M.CFG.turnStepPx then px = -_M.CFG.turnStepPx end
                local x0, y0 = _M.CFG.turnOrigin.x, _M.CFG.turnOrigin.y
                swipe(x0, y0, x0 + px, y0, math.min(450, math.max(130, math.abs(px) * 1.6)))
            else
                miss = miss + 1
                if opts.onStep then opts.onStep(i, nil, r, nil) end
                if miss >= 2 then return lastDiff, "no_target", r end
            end
        end
        sleep(opts.stepMs or 400)
    end
    return lastDiff, "max_attempts", lastRes
end

return _M
