-- 脚本/tasks/fishing.lua
-- 自动钓鱼功能
-- 设备分辨率 720x1280，横屏显示（rotate=1），脚本坐标基于横屏 1280x720
--
-- ===== 提竿精度方案：预测式定时提竿 =====
-- 实测本机一次实时取像约 95~130ms（耗时与区域大小基本无关），浮标速度约 0.4~1.5px/ms，
-- 也就是"取到"浮标时它已经又走了几十像素——靠"看到进区再点"永远点不准。
-- 因此把浮标看成一条在 [zoneY1, zoneY2] 之间来回反射、速度恒定的三角波：
--   1) 取像只用于估计速度 v 与相位（最近一次采样点 + 时刻）；
--   2) 只在"目标时刻已经很近"（≤ COMMIT_WINDOW_MS）时才提交提竿，期间持续取像刷新相位，
--      这样预测误差只累积一小段，避免长时间盲等；
--   3) 在 tCross - D 时刻精确提竿（D = 取像滞后 + 触控处理延迟，自适应）；
--   4) 提竿后立刻复核定格位置（命中后指针会定格，稍后指针会消失），
--      按 偏差/v 修正 D —— 时间域自适应，与鱼速无关。
-- 定时为 sleep + 忙等，实测可达 ±2ms 精度。
-- 判定分档（复核定格位置）：完美 = 完美区内；有效 = 上 43px / 下 44px；其余 = 出界。
--
-- 弹窗处理：非追踪阶段每 ~1s 调用一次 popup.checkLoginBonus()。
-- 状态判定：合并 DO1/DO3/DO4 为一次取像；追踪阶段不做状态比色，以省取像。

local logger = require("core.logger")
local pixel = require("core.pixel")
local dispatcher = require("core.dispatcher")
local popup = require("core.popup")

local M = { name = "钓鱼" }

-- ============ 特征比色串（"x|y|BBGGRR-偏色,..."，颜色为原 Python RRGGBB 转 BBGGRR） ============
-- DO1：可点击"开始"状态
local DO1 = "1182|485|00CFCF-0F0F0F,1180|496|00DDDE-0F0F0F,1179|508|3675B5-0F0F0F,"
    .. "1179|517|07F3F3-0F0F0F,1178|530|02FFFF-0F0F0F,1177|547|26487B-0F0F0F,"
    .. "1157|546|4AF7F7-0F0F0F,1155|549|57F0F0-0F0F0F,1205|548|A6B7C8-0F0F0F"

-- DO2：备用状态特征（原 Python 中定义未参与主循环判断）
local DO2 = "1187|494|7D5C25-0F0F0F,1174|502|304459-0F0F0F,1161|508|7C5C24-0F0F0F,"
    .. "1163|520|7D6527-0F0F0F,1162|530|565C5D-0F0F0F,1163|539|786437-0F0F0F,"
    .. "1183|538|7D6A29-0F0F0F,1195|536|776F4C-0F0F0F,1206|527|112A4C-0F0F0F,"
    .. "1211|512|79511B-0F0F0F"

-- DO3：鱼上钩/结算相关状态
local DO3 = "1183|494|006D6D-0F0F0F,1182|509|162F50-0F0F0F,1181|520|017979-0F0F0F,"
    .. "1177|536|017F7F-0F0F0F,1157|535|027676-0F0F0F,1176|547|3D4A5F-0F0F0F,"
    .. "1181|553|162741-0F0F0F,1186|548|1E2F49-0F0F0F,1199|542|172B4C-0F0F0F"

-- DO4：提竿状态
local DO4 = "1186|494|F8B446-0F0F0F,1168|515|FBD451-0F0F0F,1165|526|FBCE50-0F0F0F,"
    .. "1165|538|E0E0D7-0F0F0F,1178|538|FAD357-0F0F0F,1199|536|3265BA-0F0F0F,"
    .. "1202|534|DDDDDD-0F0F0F,1202|519|EBDCB1-0F0F0F,1193|501|FBC84E-0F0F0F"

-- TARGET：完美区域提示文字特征
local TARGET = "499|108|F7F9FB-0F0F0F,499|109|F7F9FB-0F0F0F,499|113|F7F9FB-0F0F0F,"
    .. "499|116|F7F9FB-0F0F0F,499|118|F7F9FB-0F0F0F,499|119|F7F9FB-0F0F0F,"
    .. "503|119|F7F7F9-0F0F0F,505|118|DD3434-0F0F0F,500|109|E15C5C-0F0F0F"

-- 结算弹窗右上角 X 按钮模板（打包在 资源/saoif.rc 内，findPic 用裸文件名引用）
local CLONE_IMG = "Fishing_clone.png"
local CLONE_ROI = { 915, 173, 961, 217 }
local CLONE_HALF_W, CLONE_HALF_H = 20, 15 -- 模板尺寸 40x31 的一半，findPic 返回左上角

local CLONE_CONFIRM_FRAMES = 3
local TOL = 15
local MATCH_RATE = 0.6

-- ============ 预测式提竿参数 ============
local TAP_DELAY_INIT = 40      -- 提竿延迟初值(ms)：模型时刻 → 游戏定格时刻（可为负：帧在调用内被抓取）
local TAP_DELAY_MIN, TAP_DELAY_MAX = -100, 400
local DELAY_EMA = 0.5          -- 延迟自适应系数
local DELAY_MAX_STEP = 60      -- 单次修正上限(ms)
local SPEED_MIN = 0.05         -- px/ms；低于该速度视为"指针静止"
local SPEED_BASE_MS = 150      -- 估速最小时间基线(ms)
local SPEED_BASE_PX = 40       -- 估速最小位移(px)
local SPEED_EMA_SCALE = 400    -- 速度平滑权重尺度(ms)
local SPEED_TOL = 0.35         -- 速度离群判定（与现值偏差超过该比例则丢弃本次估计）
local MOVE_MIN_PX = 3          -- 最近两个采样点位移小于该值视为"指针未动"
local MIN_TAP_GAP_MS = 25      -- 安排定时提竿时至少留出的余量(ms)
local COMMIT_WINDOW_MS = 1200  -- 目标时刻在该窗口内即可提交（模型可信时直接等下一个经过点）
local FIT_MAX_RMS_PX = 10      -- 拟合残差(RMS)超过该值认为样本不含同一段运动，放弃本次拟合
local LOOKAHEAD_MS = 1500      -- nextCrossing 搜索上限（超过认为模型异常）
local TRACK_TIMEOUT_MS = 8000  -- 单次追踪最长时间(ms)
local VERIFY_GAP_MS = 60       -- 复核取像间隔(ms)
local FROZEN_PX = 4            -- 两次复核位置差 ≤ 该值视为定格
local HIT_RADIUS_PX = 70       -- 定格位置距目标中心 ≤ 该值算命中（用于修 D）
local SAMPLES_MAX = 16
local ZONE_MIN_H = 6
local POPUP_CHECK_MS = 1000
local VALID_ABOVE = 43
local VALID_BELOW = 44

local HUD_SIZE = 16
local HUD_X, HUD_Y = 20, 150
local HUD_W, HUD_H = 560, 180

-- 从界面读取配置
function M.readConfig(handle)
    local function num(page, id, def)
        local v = tonumber(getUIText(handle, page, id))
        return v or def
    end
    return {
        loopTime    = num(1, "edLoopTime", 45),
        maxCatch    = num(1, "edMaxCatch", 0),
        clickX      = num(1, "edClickX", 1173),
        clickY      = num(1, "edClickY", 510),
        scanX       = num(1, "edScanX", 1015),
        zoneY1      = num(1, "edZoneY1", 123),
        zoneY2      = num(1, "edZoneY2", 524),
        showHud     = getUIChecked(handle, 1, "chkShowHud"),
        debugColors = getUIChecked(handle, 1, "chkDebugColors"),
        debugTrace  = getUIChecked(handle, 1, "chkDebugTrace"),
    }
end

local function doTap(cfg)
    tap(cfg.clickX, cfg.clickY)
end

local function isMatch(colorStr)
    local m, n = pixel.matchRatio(colorStr, TOL)
    return n > 0 and m >= n * MATCH_RATE
end

local function findClone()
    local r, cx, cy = findPic(CLONE_ROI[1], CLONE_ROI[2], CLONE_ROI[3], CLONE_ROI[4],
        CLONE_IMG, "101010", 0, 0.8)
    if r ~= -1 and cx ~= -1 then
        return cx, cy
    end
    return nil
end

-- ============ 三角波模型 ============
-- 把无限延伸的直线坐标 u 反射回 [ymin, ymax]（三角波折叠）
local function foldY(u, ymin, ymax)
    local span = ymax - ymin
    local w = span * 2
    local x = (u - ymin) % w
    if x < 0 then x = x + w end
    if x > span then x = w - x end
    return ymin + x
end

-- 模型位置：锚点(t0, y0, dir)，速度 v，求 t 时刻位置
local function posAt(t0, y0, dir, v, t, ymin, ymax)
    return foldY(y0 + dir * v * (t - t0), ymin, ymax)
end

-- 求 t >= tMin 时下一次经过 yc 的时刻（步进 + 线性插值；三角波分段线性，插值即精确解）
local function nextCrossing(t0, y0, dir, v, yc, tMin, ymin, ymax)
    if not v or v < SPEED_MIN then return nil end
    local span = ymax - ymin
    local period = 2 * span / v
    local tLimit = tMin + period * 2
    local step = 3
    local tPrev, yPrev = t0, y0
    local tt = t0
    while tt <= tLimit do
        tt = tt + step
        local y = posAt(t0, y0, dir, v, tt, ymin, ymax)
        if tt >= tMin and (yPrev - yc) * (y - yc) <= 0 and y ~= yPrev then
            local tc = tPrev + step * (yc - yPrev) / (y - yPrev)
            if tc >= tMin then return tc end
        end
        tPrev, yPrev = tt, y
    end
    return nil
end

-- t 时刻的运动方向：+1 向下（y 增大）/ -1 向上
local function dirAt(t0, y0, dir, v, t, ymin, ymax)
    local a = posAt(t0, y0, dir, v, t - 1, ymin, ymax)
    local b = posAt(t0, y0, dir, v, t + 1, ymin, ymax)
    if b > a then return 1 elseif b < a then return -1 else return 0 end
end

-- 等待到指定时刻（sleep + 忙等，实测 ±2ms）
local function waitUntil(t)
    local d = t - tickCount()
    if d > 8 then sleep(d - 6) end
    while tickCount() < t do end
end

-- ============ 追踪提竿（阻塞） ============
local function trackFish(cfg, st, ps0, pe0, nd0, tb0, ta0, onAttempt)
    local ymin, ymax = cfg.zoneY1, cfg.zoneY2
    local zone = { ps = ps0, pe = pe0 }
    local samples = {}
    local speed = st.speed
    local dir = nil
    local deadline = tickCount() + (cfg.trackTimeoutMs or TRACK_TIMEOUT_MS)
    local phase = "track"
    local pending = nil

    local function push(tb, ta, y)
        -- t 用调用前时刻：实测截图在调用瞬间抓帧（用返回时刻会把取像耗时抖动带入模型）
        samples[#samples + 1] = { t = tb, tb = tb, ta = ta, y = y }
        if #samples > SAMPLES_MAX then table.remove(samples, 1) end
    end

    -- 用"最近一段连续同向样本"的两端估速度（方向反转即停止回溯）
    local function updateSpeed()
        local n = #samples
        if n < 2 then return end
        local last = samples[n]
        local sign = nil
        local i = n - 1
        while i >= 1 do
            local dy = samples[i + 1].y - samples[i].y
            if dy ~= 0 then
                local sg = dy > 0 and 1 or -1
                if sign == nil then
                    sign = sg
                elseif sg ~= sign then
                    return
                end
            end
            local dt = last.t - samples[i].t
            local d = last.y - samples[i].y
            if dt >= SPEED_BASE_MS and math.abs(d) >= SPEED_BASE_PX then
                local v = math.abs(d) / dt
                if v >= SPEED_MIN then
                    if not speed or math.abs(v - speed) <= speed * SPEED_TOL then
                        local w = math.min(1, dt / SPEED_EMA_SCALE)
                        speed = speed and (speed + w * (v - speed)) or v
                        st.speed = speed
                    end
                end
                return
            end
            i = i - 1
        end
    end

    -- 方向取自最近两个采样点（最新信息）
    local function updateDir()
        local n = #samples
        if n >= 2 then
            local a, b = samples[n - 1], samples[n]
            if b.y > a.y then
                dir = 1
            elseif b.y < a.y then
                dir = -1
            end
        end
    end

    -- 用最近样本对 (方向, 速度, 相位) 做网格搜索拟合：三角波模型的最优解
    local function fitModel(dHint)
        local n = #samples
        if n < 3 then return nil end
        local last = samples[n]
        local best
        local function evalModel(d, v, y0)
            local err = 0
            for i = 1, n do
                local s = samples[i]
                local e = foldY(y0 + d * v * (last.tb - s.tb), ymin, ymax) - s.y
                err = err + e * e
            end
            return err
        end
        local dirs = dHint and { dHint } or { 1, -1 }
        -- 锚点处模型位置 = 最后采样点位置（折叠函数在 [ymin,ymax] 内是恒等），
        -- 因此只需一维扫描速度，避免二维粗扫落到伪极小值
        local y0 = last.y
        local VMIN, VMAX, NV = 0.04, 2.0, 40
        for _, d in ipairs(dirs) do
            for iv = 0, NV - 1 do
                local v = VMIN * (VMAX / VMIN) ^ (iv / (NV - 1))
                local err = evalModel(d, v, y0)
                if not best or err < best.err then
                    best = { err = err, v = v, y0 = y0, d = d }
                end
            end
        end
        -- 细化：速度 ±8%（步长 0.8%），相位 ±5px
        if best then
            local refV, refY = best.v, best.y0
            for iv = -6, 6 do
                local v = refV * (1 + iv * 0.012)
                if v > SPEED_MIN * 0.5 then
                    for iy = -4, 4 do
                        local yy = refY + iy
                        if yy >= ymin and yy <= ymax then
                            local err = evalModel(best.d, v, yy)
                            if err < best.err then best.err, best.v, best.y0 = err, v, yy end
                        end
                    end
                end
            end
        end
        return best
    end

    local function moving()
        local n = #samples
        if n < 2 then return false end
        return math.abs(samples[n].y - samples[n - 1].y) >= MOVE_MIN_PX
    end

    -- 相位连续性检查：新采样点与"上一点 + 当前速度(含反弹)"的预测偏离过大 →
    -- 视为指针重置（命中后回到底部）或漏采，丢弃旧样本，只保留最近两点
    local function checkJump()
        local n = #samples
        if n < 3 then return end
        local prev, last = samples[n - 1], samples[n]
        local v = speed or 0.35
        local pred = posAt(prev.tb, prev.y, dir or 1, v, last.tb, ymin, ymax)
        if math.abs(last.y - pred) > 45 then
            samples = { prev, last }
            dir = nil
            if st.debug then
                logger.debug(string.format("相位重置: 实测=%d 预测=%.0f", last.y, pred))
            end
        end
    end

    local function traceStr(now)
        local parts = {}
        for _, s in ipairs(samples) do
            parts[#parts + 1] = string.format("%d,%d,%d", s.tb - now, s.y, s.ta - now)
        end
        return table.concat(parts, ";")
    end

    if nd0 then push(tb0, ta0, nd0) end

    while true do
        if tickCount() >= deadline then return "timeout" end

        ---------------------------------------------------------------
        -- 复核阶段：提竿后立即取像（命中后指针定格，随后指针会消失）
        ---------------------------------------------------------------
        if phase == "verify" then
            -- 提竿后尽快连续取像：命中后指针定格，随后游戏会把指针收走（约 300ms）
            local res = {}
            local vps, vpe, vy = pixel.scanColumn(cfg.scanX, ymin, ymax)
            res[1] = { dt = tickCount() - pending.tapAt, ps = vps, pe = vpe, y = vy }
            if st.debug then
                local parts = {}
                for _, r in ipairs(res) do
                    parts[#parts + 1] = string.format("+%dms:浮标=%s 区域=%s-%s",
                        r.dt, r.y and tostring(r.y) or "无",
                        r.ps and tostring(r.ps) or "-", r.pe and tostring(r.pe) or "-")
                end
                logger.debug("复核取像 " .. table.concat(parts, " | "))
            end

            -- 取提竿后第一个有效浮标位置作为定格位置
            local yStop
            for _, r in ipairs(res) do
                if r.y then yStop = r.y break end
            end

            if yStop then
                local err = (yStop - pending.yc) * pending.dirCross
                if math.abs(err) <= HIT_RADIUS_PX * 2 then
                    local stepMs = err / (speed and speed > SPEED_MIN and speed or 1)
                    if stepMs > DELAY_MAX_STEP then stepMs = DELAY_MAX_STEP end
                    if stepMs < -DELAY_MAX_STEP then stepMs = -DELAY_MAX_STEP end
                    st.tapDelay = math.max(TAP_DELAY_MIN, math.min(TAP_DELAY_MAX, st.tapDelay + DELAY_EMA * stepMs))
                end
                local perfect = yStop >= pending.ps and yStop <= pending.pe
                local valid = yStop >= pending.ps - VALID_ABOVE and yStop <= pending.pe + VALID_BELOW
                if perfect then
                    st.perfect = st.perfect + 1
                elseif valid then
                    st.valid = st.valid + 1
                else
                    st.miss = st.miss + 1
                end
                logger.info(string.format("提竿结果: %s 定格=%d 区域=%d-%d 偏差=%+.0fpx 延迟→%dms",
                    perfect and "完美" or (valid and "有效" or "出界"),
                    yStop, pending.ps, pending.pe, yStop - pending.yc, math.floor(st.tapDelay + 0.5)))
            else
                st.unknown = st.unknown + 1
                logger.info("提竿后未见浮标（特效/结算过渡），本次结果未知")
            end
            if st.debug and pending.trace then
                logger.debug("提竿样本: " .. pending.trace)
            end
            phase = "track"
            pending = nil
            samples = {}
            dir = nil
            if onAttempt then onAttempt() end
        else
        ---------------------------------------------------------------
        -- 追踪阶段：取像 → 更新速度/相位 → 目标临近时才提交提竿
        ---------------------------------------------------------------
            local tBefore = tickCount()
            local nps, npe, nd = pixel.scanColumn(cfg.scanX, ymin, ymax)
            local tSample = tickCount()
            if not nps then return "gone" end
            if math.abs(nps - zone.ps) > 1 or math.abs(npe - zone.pe) > 1 then
                zone.ps, zone.pe = nps, npe
                samples = {}
                dir = nil
            end
            if nd then push(tBefore, tSample, nd) end
            checkJump()
            updateSpeed()
            updateDir()
            if st.debug and #samples > 0 and #samples % 4 == 0 then
                logger.debug("样本: " .. traceStr(samples[#samples].t))
            end

            if cfg.watchOnly then
                st.watchN = (st.watchN or 0) + 1
                if nd and st.watchN % 2 == 0 then
                    logger.info(string.format("采样 %d,%d,%d", tBefore, nd, tSample))
                end
            end

            if not cfg.watchOnly and #samples >= 2 and moving() then
                local last = samples[#samples]
                local d0 = dir
                if not d0 then
                    local prev = samples[#samples - 1]
                    if last.y > prev.y then d0 = 1 elseif last.y < prev.y then d0 = -1 end
                end
                if d0 then
                    local yc = (zone.ps + zone.pe) / 2
                    local vHint = speed or st.lastSpeed or 0.35
                    local tMin = tickCount() + MIN_TAP_GAP_MS + st.tapDelay
                    local anchorY = last.y
                    local tCross
                    -- A. 预测式：本鱼速度已验证 → 直接用锚点+速度；否则样本够就拟合
                    if st.speedTrusted and speed then
                        tCross = nextCrossing(last.t, anchorY, d0, speed, yc, tMin, ymin, ymax)
                    elseif #samples >= 3 then
                        local span = samples[#samples].tb - samples[1].tb
                        local spread = math.abs(samples[#samples].y - samples[1].y)
                        if span >= 100 and spread >= 30 then
                            local fit = fitModel(d0)
                            if fit then
                                local rms = math.sqrt(fit.err / #samples)
                                if st.debug then
                                    logger.debug(string.format("拟合: v=%.3f 方向=%d 均方根=%.1fpx 样本=%d 锚点=%.0f 目标=%.0f",
                                        fit.v, fit.d, rms, #samples, fit.y0, yc))
                                end
                                if rms <= FIT_MAX_RMS_PX then
                                    speed = fit.v
                                    st.speed = speed
                                    st.speedTrusted = true
                                    d0 = fit.d
                                    anchorY = fit.y0
                                    tCross = nextCrossing(last.t, fit.y0, fit.d, speed, yc, tMin, ymin, ymax)
                                end
                            end
                        end
                    end
                    if tCross and (tCross - tickCount()) > COMMIT_WINDOW_MS then
                        tCross = nil
                    end
                    -- B. 快速通道：还没有模型时，按"漂移量"估算落点，落在有效区内就立即出手
                    local quick = false
                    if not tCross then
                        local tend = (tickCount() - last.tb) + st.tapDelay + 40
                        local drift = math.abs(vHint * tend)
                        local pad = math.min(drift * 0.35 + 18, 55)
                        local est = last.y + d0 * vHint * tend
                        if est >= zone.ps - VALID_ABOVE + pad and est <= zone.pe + VALID_BELOW - pad then
                            tCross = tickCount() + 5
                            quick = true
                        end
                    end
                    if tCross then
                        local tTap = tCross - st.tapDelay
                        local dirCross = dirAt(last.t, anchorY, d0, speed or vHint, tCross, ymin, ymax)
                        local trace = st.debug and traceStr(last.t) or nil
                        local waitMs = tTap - tickCount()
                        waitUntil(tTap)
                        doTap(cfg)
                        st.lastSpeed = speed or vHint
                        st.taps = st.taps + 1
                        logger.info(string.format("提竿%d: %s 区域=%d-%d 目标=%d 采样=%d 速度=%.2f 延迟=%dms 等待=%dms",
                            st.taps, quick and "快速" or "预测", zone.ps, zone.pe, math.floor(yc + 0.5), last.y,
                            speed or vHint, math.floor(st.tapDelay + 0.5), math.floor(waitMs)))
                        pending = {
                            tapAt = tickCount(),
                            tCross = tCross,
                            yc = yc,
                            ps = zone.ps,
                            pe = zone.pe,
                            dirCross = dirCross,
                            trace = trace,
                        }
                        phase = "verify"
                    end
                end
            end
        end
    end
end

function M.run(cfg)
    local successCount = 0
    local hud = nil
    local hudText = ""
    local zoneMinH = cfg.zoneMinH or ZONE_MIN_H
    local st = {
        speed = nil,
        tapDelay = cfg.tapDelay or TAP_DELAY_INIT,
        taps = 0,
        perfect = 0,
        valid = 0,
        miss = 0,
        unknown = 0,
        debug = cfg.debugTrace and true or false,
    }

    local runStart = tickCount()

    local function updateHud()
        if not cfg.showHud then return end
        local elapsedS = (tickCount() - runStart) / 1000
        local spd = successCount > 0 and math.floor(elapsedS / successCount + 0.5) or 0
        local text = string.format("钓鱼中 成功 %d 条  速度 %d 秒/条\n提竿 %d 完美 %d 有效 %d 空 %d 未知 %d 延迟 %dms",
            successCount, spd, st.taps, st.perfect, st.valid, st.miss, st.unknown, math.floor(st.tapDelay + 0.5))
        if text == hudText then return end
        hudText = text
        if not hud then hud = createHUD() end
        showHUD(hud, text, HUD_SIZE, "0xffffffff", "0xCC222222", 0, HUD_X, HUD_Y, HUD_W, HUD_H)
    end

    logger.info("=== 开始钓鱼 ===")
    local dw, dh = getDisplaySize()
    logger.info(string.format("设备: %s %s SDK=%d 显示=%dx%d rotate=%d",
        tostring(getBrand()), tostring(getModel()), getSdkVersion(), dw, dh, getDisplayRotate()))
    logger.info(string.format("参数: 单轮超时=%ds 目标次数=%d 按钮=(%d,%d) 扫描列X=%d 区域Y=%d~%d",
        cfg.loopTime, cfg.maxCatch, cfg.clickX, cfg.clickY, cfg.scanX, cfg.zoneY1, cfg.zoneY2))

    -- 关闭截图缓存，保证取到实时画面（实测每帧 ~100ms，方案基于预测而非实时跟踪）
    setSnapCacheTime(0)

    if cfg.debugColors then
        logger.info("首帧颜色采样:")
        pixel.dumpPoints(DO1, "DO1")
        pixel.dumpPoints(DO2, "DO2")
        pixel.dumpPoints(DO3, "DO3")
        pixel.dumpPoints(DO4, "DO4")
        pixel.dumpPoints(TARGET, "Target")
    end

    local endTime = tickCount() + cfg.loopTime * 1000
    local cloneSkip = 0
    local zoneLogged = false
    local tracking = false
    local nextPopupCheck = 0
    updateHud()

    while tickCount() < endTime do
        if not tracking and tickCount() >= nextPopupCheck then
            nextPopupCheck = tickCount() + POPUP_CHECK_MS
            if popup.checkLoginBonus() then
                cloneSkip = 0
                zoneLogged = false
            end
        end

        local textMatched = isMatch(TARGET)
        local do1, do3Matched, do4
        if not textMatched then
            -- 完美区提示可见 = 鱼在拉锯中，不必做状态比色（省一次取像）
            local s = pixel.matchStates({ DO1 = DO1, DO3 = DO3, DO4 = DO4 }, TOL, MATCH_RATE)
            do1, do3Matched, do4 = s.DO1, s.DO3, s.DO4
        end

        if do1 then
            logger.info("点击开始")
            doTap(cfg)
            -- 每次撒饵都是一条新鱼，速度必须重新学习（速度随鱼而定，跨鱼不通用）
            st.speed = nil
            st.speedTrusted = false
            zoneLogged = false
            updateHud()
        end

        if do4 then
            logger.info("提竿")
            doTap(cfg)
            updateHud()
        end

        if textMatched and not do3Matched then
            local tb0 = tickCount()
            local pStart, pEnd, needle = pixel.scanColumn(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
            local ta0 = tickCount()
            if pStart and pEnd and (pEnd - pStart) >= zoneMinH then
                if not zoneLogged then
                    logger.info(string.format("完美区域: %d-%d", pStart, pEnd))
                    zoneLogged = true
                end
                tracking = true
                local reason = trackFish(cfg, st, pStart, pEnd, needle, tb0, ta0, updateHud)
                tracking = false
                zoneLogged = false
                if reason == "timeout" then
                    logger.warn("追踪超时，回主循环重新判定")
                end
            else
                zoneLogged = false
            end
        else
            zoneLogged = false
        end

        if not textMatched and do3Matched then
            cloneSkip = cloneSkip + 1
            if cloneSkip >= CLONE_CONFIRM_FRAMES then
                cloneSkip = 0
                local cx, cy = findClone()
                if cx then
                    successCount = successCount + 1
                    logger.info(string.format("钓鱼成功! +1 (共 %d)", successCount))
                    updateHud()
                    tap(cx + CLONE_HALF_W, cy + CLONE_HALF_H)
                    endTime = tickCount() + cfg.loopTime * 1000
                    sleep(400)
                end
            end
        end

        if cfg.maxCatch > 0 and successCount >= cfg.maxCatch then
            logger.info(string.format("已达目标次数 %d，提前结束", cfg.maxCatch))
            break
        end

        tracking = textMatched
    end

    if hud then
        hideHUD(hud)
        hud = nil
    end
    setSnapCacheTime(100)
    local elapsedS = (tickCount() - runStart) / 1000
    logger.info(string.format("统计: 成功=%d 提竿=%d 完美=%d(%.0f%%) 有效=%d(%.0f%%) 空竿/出界=%d 未知=%d 延迟=%.0fms 速度=%.2fpx/ms 用时=%.0fs",
        successCount, st.taps,
        st.perfect, st.taps > 0 and st.perfect * 100 / st.taps or 0,
        st.valid, st.taps > 0 and st.valid * 100 / st.taps or 0,
        st.miss, st.unknown, st.tapDelay, st.speed or 0, elapsedS))
    logger.info(string.format("========== 结束，共钓鱼 %d 次 ==========", successCount))
end

dispatcher.register(M)

return M
