-- 脚本/core/facing.lua
-- 角色朝向识别 —— 小地图上的白色标记精灵会随「角色转身」旋转(与视野锥相互独立)
-- 做法参考 StarRailCopilot wiki/MinimapTracking 的「角色朝向识别」:
--   ① 按白色阈值把标记抠成二值图(等同 SRC 的 color_similarity_2d 抽取箭头);
--   ② 用 5° 步进的旋转拼合图做【一次】模板匹配(模板/被搜图反转技巧),
--      命中格索引 k → 角度 = k*5°(cv2 约定: 逆时针为正, 需 calib 标定到罗盘方位)。
-- 资产: 8列×9行 × 48px 的严格二值拼合图(内嵌 base64, 运行时写到设备再读入)
--
-- 用法:
--   local fc = require("core.facing")
--   local r = fc.detect()                  -- {angle=, bearing=, sim=, col=, row=, x=, y=}
--   local r = fc.detectStable(3)           -- 多帧投票(角度聚类)
--   fc.calib(-90)                          -- 一次性标定: 让角色朝正北, 读出 A → calib(-A)
--   print(fc.text(r.bearing))
--
-- 说明:
--   * 标记中心必须已知: 城镇小地图固定在 (1181,100); 大地图先用 core.viewcone 定位白环再传入;
--   * sim < SIM_MIN 视为「不是该精灵」(副本/竞技场是另一种标记), 此时返回 low 标记;
--   * 单次耗时主要花在 matchTemplate 上(约 3×10^8 次乘加), 建议只在需要时调用。

local _M = {}

_M.MONT_B64 = "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"
_M.S, _M.COLS, _M.ROWS, _M.STEP = 36, 8, 9, 5
_M.SIM_MIN = 0.65
_M.CENTER = { x = 1181, y = 100 }
_M.CALIB = 0
_M.LOW_ROT = 0

local mat

-- 把拼合图写到设备(saoif_tpl/facing_mont.png)并读成 Mat
local function ensure()
    if mat then return true end
    local dir = getSdPath() .. "/saoif_tpl"
    pcall(mkdir, dir)
    local p = dir .. "/facing_mont.png"
    -- 每次都重写: 拼合图升级后自动生效(避免旧资产残留)
    local f = io.open(p, "wb")
    if not f then return false end
    f:write(decodeBase64(_M.MONT_B64))
    f:close()
    local m = cv.imread(p, cv.IMREAD_COLOR)
    if not m then return false end
    mat = m
    return true
end

function _M.ready()
    return ensure()
end

-- 标定: 拼合图角度 → 罗盘方位 的固定偏移
function _M.calib(offset)
    _M.CALIB = offset or 0
end

function _M.toBearing(angle)
    if not angle then return nil end
    local b = (angle + _M.CALIB) % 360
    if b < 0 then b = b + 360 end
    return b
end

_M.DIRS = { "北", "东北", "东", "东南", "南", "西南", "西", "西北" }
function _M.text(bearing)
    local i = math.floor(((bearing or 0) % 360) / 45 + 0.5) % 8 + 1
    return _M.DIRS[i]
end

-- 单帧识别
-- center: 可选 {x=,y=}; 省略用 _M.CENTER
function _M.detect(center)
    if not ensure() then return nil, "no_montage" end
    local cx = center and center.x or _M.CENTER.x
    local cy = center and center.y or _M.CENTER.y
    local half = math.floor(_M.S / 2)
    local tmp = getSdPath() .. "/saoif_tpl/facing_crop.png"

    -- THRESH_BINARY=0: >205 → 255, 其余 → 0
    local okb = binaryRect(tmp, cx - half, cy - half, cx + half - 1, cy + half - 1, 0, 205, 255)
    if okb ~= 1 then return nil, "no_crop" end
    local crop = cv.imread(tmp, cv.IMREAD_COLOR)
    if not crop then return nil, "no_crop_mat" end

    local res = cv.Mat.new()
    cv.matchTemplate(mat, crop, res, cv.TM_CCOEFF_NORMED)
    local mn = cv.newPoint(0, 0)
    local mx = cv.newPoint(0, 0)
    local mnv = cv.newDouble(0)
    local mxv = cv.newDouble(0)
    cv.minMaxLoc(res, mnv, mxv, mn, mx)
    local p = cv.getPoint(mx)
    local sim = cv.getDouble(mxv)

    crop:release(); res:release()
    cv.deletePtr(mn); cv.deletePtr(mx); cv.deletePtr(mnv); cv.deletePtr(mxv)

    local col = math.floor(p.x / _M.S + 0.5)
    local row = math.floor(p.y / _M.S + 0.5)
    local o = { sim = sim, col = col, row = row, x = cx, y = cy }
    if col < 0 or col >= _M.COLS or row < 0 or row >= _M.ROWS then return nil, "outside" end
    if sim < _M.SIM_MIN then
        o.low = true
        return o
    end
    o.angle = (row * _M.COLS + col) * _M.STEP
    o.bearing = _M.toBearing(o.angle)
    return o
end

-- 角度差(-180..180)
local function diff180(d)
    d = d % 360
    if d > 180 then d = d - 360 end
    return d
end

-- 多帧投票: 取角度最集中的一簇, 返回该簇的圆均值
function _M.detectStable(n, center, opts)
    opts = opts or {}
    n = n or 3
    local tol = opts.tol or 10
    local minVotes = opts.minVotes or 2
    local interval = opts.intervalMs or 120
    local items = {}
    for i = 1, n do
        items[i] = _M.detect(center)
        if i < n then sleep(interval) end
    end
    local valid = {}
    for i = 1, #items do
        local it = items[i]
        if it and it.angle then valid[#valid + 1] = it end
    end
    if #valid == 0 then return nil, "no_valid" end
    if #valid < minVotes then
        local it = valid[1]
        it.single = true
        return it
    end
    local bestSet, bestN = nil, 0
    for i = 1, #valid do
        local s = { valid[i] }
        for j = 1, #valid do
            if j ~= i and math.abs(diff180(valid[j].angle - valid[i].angle)) <= tol then
                s[#s + 1] = valid[j]
            end
        end
        if #s > bestN then bestN, bestSet = #s, s end
    end
    if bestN < minVotes then return nil, "low_agree" end
    local vx, vy, ws, sim = 0, 0, 0, 0
    for _, it in ipairs(bestSet) do
        local w = it.sim
        local a = math.rad(it.angle)
        vx = vx + w * math.cos(a)
        vy = vy + w * math.sin(a)
        ws = ws + w
        sim = sim + it.sim
    end
    local angle = math.deg(math.atan2(vy, vx)) % 360
    local spread = 0
    for _, it in ipairs(bestSet) do
        local d = math.abs(diff180(it.angle - angle))
        if d > spread then spread = d end
    end
    local o = { angle = angle, bearing = _M.toBearing(angle), sim = sim / #bestSet,
                votes = #bestSet, agree = #bestSet / #valid, spread = spread }
    return o
end

return _M
