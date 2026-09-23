-- 脚本/tasks/fishing.lua
-- 自动钓鱼功能
-- 移植自 D:\project\AutoScript\SaoifAutoScript\tasks\Fishing\script_task.py
-- 设备分辨率 720x1280，横屏显示（rotate=1），脚本坐标基于横屏 1280x720
--
-- 性能说明：追踪阶段每次只取一列像素（1 次取像，本机约 50ms）直接找浮标颜色；
--           状态判定把同一区域的 DO1/DO3/DO4 合并为一次取色；追踪期间不再做
--           弹窗找图；提竿后只复核一帧（命中后仪表定格、位置稳定）。
-- 弹窗处理：非追踪阶段每 ~1s 调用一次 popup.checkLoginBonus()（避免每轮 findPic）。
-- 参数覆盖：HIT_MARGIN/LEAD_* 等可在 cfg 里传入覆盖（用于批量对比实验）。
--
-- 判定分档（提竿后取一帧读"定格位置"）：
--   完美：定格位置在完美区域内（绿条 ps~pe）
--   有效：定格位置在有效区内（完美区域上方 43px ~ 下方 44px，游戏实际判定范围）
--   出界：超出有效区（浪费的一次点击）
-- 提前量与鱼速：不同鱼速下"触发取样 → 定格位置"的位移基本恒定（实测约 30px），
--               因此用距离型提前量 LEAD_DIST（不假设固定时间）；触发点沿运动
--               方向前推 LEAD_DIST 像素落在区域内即出手；LEAD_DIST 每次按定格
--               偏差（相对区域中心）自动修正，自动适配每一条鱼。
-- 实测：距离型提前量 + 自适应，15 条鱼 完美率约 55%、有效 100%、15/15 上钩、14.9s/条。

local logger = require("core.logger")
local pixel = require("core.pixel")
local dispatcher = require("core.dispatcher")
local popup = require("core.popup")

local M = { name = "钓鱼" }

-- ============ 特征比色串（"x|y|BBGGRR-偏色,..."，颜色为原 Python RRGGBB 转 BBGGRR） ============
-- 坐标均为横屏 1280x720 空间（设备 720x1280 竖屏 + rotate=1 横屏显示）
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
-- 对应 Python I_CLONE: roi_front=(917,180,40,31), roi_back=(915,173,46,44), threshold=0.8
local CLONE_IMG = "Fishing_clone.png"
local CLONE_ROI = { 915, 173, 961, 217 }
local CLONE_HALF_W, CLONE_HALF_H = 20, 15 -- 模板尺寸 40x31 的一半，findPic 返回左上角

local CLONE_CONFIRM_FRAMES = 5 -- 连续 N 帧处于 DO3 状态判定为成功（替代原结算图判定）
local TOL = 15                 -- 逐通道容差，对应原 Python tol=15
local MATCH_RATE = 0.6         -- 点匹配率阈值，对应原 Python m >= n * 0.6

-- ============ 精准提竿参数 ============
local HIT_MARGIN = 0       -- 浮标位置与完美区域边界的容差(px)；0=只有真正进入区域才提竿
local ZONE_MIN_H = 6       -- 完美区域最小高度(px)，过滤瞬时单像素误判
local TRACK_POLL_MS = 1200 -- 单次提竿追踪的最长时间(ms)，超时回主循环刷新状态
local LEAD_MIN_V = 0.1     -- 速度低于该值(px/ms)的浮标直接等它进区，不用提前量
local LEAD_DIST_INIT = 30  -- 提前量初值(px)：触发点相对区域的提前距离
local LEAD_DIST_MIN = 8    -- 提前量下限(px)
local LEAD_DIST_MAX = 60   -- 提前量上限(px)
local LEAD_EMA = 0.3       -- 提前量自适应系数（每次命中按定格偏差修正的比例）
local TAP_GUARD_MS = 500   -- 提竿后忽略触发的时长(ms)，替代"等浮标离开"的轮询取像
local POPUP_CHECK_MS = 1000 -- 弹窗检测间隔(ms)
local VALID_ABOVE = 43     -- 有效区：完美区域上方(px)
local VALID_BELOW = 44     -- 有效区：完美区域下方(px)

-- HUD 样式（内容较多，框要够大）
local HUD_SIZE = 16        -- 字体大小
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
        zoneY2      = num(1, "edZoneY2", 523),
        showHud     = getUIChecked(handle, 1, "chkShowHud"),
        debugColors = getUIChecked(handle, 1, "chkDebugColors"),
    }
end

local function doTap(cfg)
    tap(cfg.clickX, cfg.clickY)
end

-- 按比率判定状态（对应 Python: 逐通道 ±15，且 ≥60% 的点匹配）
local function isMatch(colorStr)
    local m, n = pixel.matchRatio(colorStr, TOL)
    return n > 0 and m >= n * MATCH_RATE
end

-- 查找结算弹窗的 X 按钮，找到返回左上角坐标
local function findClone()
    local r, cx, cy = findPic(CLONE_ROI[1], CLONE_ROI[2], CLONE_ROI[3], CLONE_ROI[4],
        CLONE_IMG, "101010", 0, 0.8)
    if r ~= -1 and cx ~= -1 then
        return cx, cy
    end
    return nil
end

-- 精准提竿：高频轮询浮标位置
--   慢速浮标（|v| < LEAD_MIN_V）：等它真正进入区域才提竿；
--   其余浮标：把当前位置沿运动方向前推 LEAD_DIST 像素，落点在区域内即提竿
--   （距离型提前量，与鱼速无关，避免不同鱼速下时间估算失准）。
-- 提竿后只取像一帧读"定格位置"，判定完美/有效/出界并自适应修正 LEAD_DIST。
-- tune 为本次运行的调参状态 { leadDist, guardUntil }
-- 返回：是否提竿, 触发时浮标位置, 是否提前量触发, 是否完美, 是否有效, 追踪耗时(ms)
local function tryPull(cfg, tune, ps, pe, needle)
    if tickCount() < tune.guardUntil then
        return false -- 提竿后的保护期，避免对着定格画面重复提竿
    end
    local hitMargin = cfg.hitMargin or HIT_MARGIN
    local leadMinV = cfg.leadMinV or LEAD_MIN_V
    local trackPollMs = cfg.trackPollMs or TRACK_POLL_MS

    local t = tickCount()
    local deadline = t + trackPollMs
    local nd, ndT = needle, t
    local prevNd, prevT = nil, nil

    -- 提竿后判定 + 提前量自适应（只取一帧：命中后仪表定格，位置稳定）
    -- 偏差 err = 沿运动方向（定格位置 - 区域中心）：>0 打点偏后（出手偏晚）→ 加大提前量。
    local function verifyAfterTap(vHint, nd0, leadUsed)
        local ps2, pe2, n2 = pixel.scanColumn(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
        if not n2 or not ps2 then
            logger.debug(string.format("提竿复核: 区域=%d-%d 提竿后取像失败", ps, pe))
            return false, false
        end
        local dir = (n2 >= nd0) and 1 or -1
        local err = dir * (n2 - (ps2 + pe2) / 2)
        local perfect = n2 >= ps2 and n2 <= pe2
        local valid = n2 >= ps2 - VALID_ABOVE and n2 <= pe2 + VALID_BELOW
        if leadUsed and vHint and math.abs(vHint) >= 0.15 then
            tune.leadDist = tune.leadDist + LEAD_EMA * err
            if tune.leadDist < LEAD_DIST_MIN then tune.leadDist = LEAD_DIST_MIN end
            if tune.leadDist > LEAD_DIST_MAX then tune.leadDist = LEAD_DIST_MAX end
        end
        logger.debug(string.format("提竿复核: 区域=%d-%d 触发=%d 定格=%d 偏差=%+.0f 提前量=%.0fpx 完美=%s 有效=%s",
            ps2, pe2, nd0, n2, err, tune.leadDist, tostring(perfect), tostring(valid)))
        return perfect, valid
    end

    while true do
        -- 慢速/已进区：取样时浮标就在区域内，直接提竿
        if nd and nd >= ps - hitMargin and nd <= pe + hitMargin then
            local vHint = (prevNd and ndT > prevT) and (nd - prevNd) / (ndT - prevT) or nil
            doTap(cfg)
            local perfect, valid = verifyAfterTap(vHint, nd, false)
            tune.guardUntil = tickCount() + TAP_GUARD_MS
            return true, nd, false, perfect, valid, tickCount() - t
        end
        -- 距离型提前量：沿运动方向前推 leadDist 像素，落点在区域内则提前出手
        if nd and prevNd and ndT > prevT then
            local v = (nd - prevNd) / (ndT - prevT)
            if math.abs(v) >= leadMinV then
                local dir = v > 0 and 1 or -1
                local pred = nd + dir * tune.leadDist
                if pred >= ps and pred <= pe then
                    doTap(cfg)
                    local perfect, valid = verifyAfterTap(v, nd, true)
                    tune.guardUntil = tickCount() + TAP_GUARD_MS
                    return true, nd, true, perfect, valid, tickCount() - t
                end
            end
        end
        if tickCount() >= deadline then
            return false
        end
        -- 高频轮询：一次取像得到区域范围与浮标位置
        local ps2, pe2, nd2 = pixel.scanColumn(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
        if not ps2 then
            return false -- 区域消失（本轮结束/进入结算）
        end
        ps, pe = ps2, pe2
        prevNd, prevT = nd, ndT
        nd, ndT = nd2, tickCount()
    end
end

function M.run(cfg)
    local successCount = 0
    local hitCount = 0     -- 命中次数（触发提竿的次数）
    local perfectCount = 0 -- 定格位置在完美区域内的次数
    local validCount = 0   -- 定格位置在有效区（完美区域上方43px~下方44px）内的次数
    local hud = nil
    local hudText = ""
    local zoneMinH = cfg.zoneMinH or ZONE_MIN_H
    local tune = {         -- 调参状态（每次运行重置）
        leadDist = cfg.leadDist or LEAD_DIST_INIT,
        guardUntil = 0,
    }

    local runStart = tickCount()

    -- HUD：成功条数/平均每条耗时 + 命中/完美/有效/提前量
    local function updateHud()
        if not cfg.showHud then return end
        local elapsedS = (tickCount() - runStart) / 1000
        local spd = successCount > 0 and math.floor(elapsedS / successCount + 0.5) or 0
        local text = string.format("钓鱼中 成功 %d 条  速度 %d 秒/条\n命中 %d 完美 %d 有效 %d 提前量 %dpx",
            successCount, spd, hitCount, perfectCount, validCount, math.floor(tune.leadDist + 0.5))
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

    -- 关闭截图缓存，保证浮标追踪时每次取到实时画面
    setSnapCacheTime(0)

    -- 首帧颜色采样调试（对应原 Python 的 _dump_colors）
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
    local tracking = false     -- 上一轮是否处于完美区域追踪阶段
    local nextPopupCheck = 0
    updateHud()

    while tickCount() < endTime do
        -- 弹窗检测：只在非追踪阶段、且间隔 POPUP_CHECK_MS 才做（findPic 开销大）
        if not tracking and tickCount() >= nextPopupCheck then
            nextPopupCheck = tickCount() + POPUP_CHECK_MS
            if popup.checkLoginBonus() then
                cloneSkip = 0
                zoneLogged = false
            end
        end

        local textMatched = isMatch(TARGET)
        local do1, do3Matched, do4
        if not (tracking and textMatched) then
            -- 追踪期间跳过 DO1/DO3/DO4 判定，省一次取像
            local st = pixel.matchStates({ DO1 = DO1, DO3 = DO3, DO4 = DO4 }, TOL, MATCH_RATE)
            do1, do3Matched, do4 = st.DO1, st.DO3, st.DO4
        end

        -- 状态1：出现开始按钮
        if do1 then
            logger.info("点击开始")
            doTap(cfg)
            zoneLogged = false
            updateHud()
        end

        -- 状态4：提竿时机
        if do4 then
            logger.info("提竿")
            doTap(cfg)
            updateHud()
        end

        -- 完美区域提示出现：高频轮询浮标，进区立即提竿
        if textMatched and not do3Matched then
            local pStart, pEnd, needle = pixel.scanColumn(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
            -- 完美区域高度至少 zoneMinH，过滤瞬时出现的单像素误判
            if pStart and pEnd and (pEnd - pStart) >= zoneMinH then
                if not zoneLogged then
                    logger.info(string.format("完美区域: %d-%d", pStart, pEnd))
                    zoneLogged = true
                end
                local hit, pos, lead, perfect, valid, trackMs = tryPull(cfg, tune, pStart, pEnd, needle)
                if hit then
                    hitCount = hitCount + 1
                    if perfect then perfectCount = perfectCount + 1 end
                    if valid then validCount = validCount + 1 end
                    local tag
                    if perfect then
                        tag = "完美"
                    elseif valid then
                        tag = "有效"
                    else
                        tag = "出界"
                    end
                    logger.info(string.format("命中!(%s) 追踪=%dms 浮标=%d 区域=%d-%d",
                        tag, trackMs, pos, pStart, pEnd))
                    updateHud()
                end
            else
                zoneLogged = false
            end
        else
            zoneLogged = false
        end

        -- DO3 状态持续出现（无文字提示）→ 结算弹窗出现 → 计数并点击 X 关闭
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
                    sleep(1000)
                end
            end
        end

        -- 达到目标次数
        if cfg.maxCatch > 0 and successCount >= cfg.maxCatch then
            logger.info(string.format("已达目标次数 %d，提前结束", cfg.maxCatch))
            break
        end

        tracking = textMatched
        sleep(30)
    end

    if hud then
        hideHUD(hud)
        hud = nil
    end
    setSnapCacheTime(100)
    local elapsedS = (tickCount() - runStart) / 1000
    logger.info(string.format("统计: 成功=%d 命中=%d 完美=%d(%.0f%%) 有效=%d(%.0f%%) 提前量=%.0fpx 用时=%.0fs",
        successCount, hitCount, perfectCount,
        hitCount > 0 and perfectCount * 100 / hitCount or 0,
        validCount, hitCount > 0 and validCount * 100 / hitCount or 0,
        tune.leadDist, elapsedS))
    logger.info(string.format("========== 结束，共钓鱼 %d 次 ==========", successCount))
end

dispatcher.register(M)

return M
