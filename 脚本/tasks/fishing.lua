-- 脚本/tasks/fishing.lua
-- 自动钓鱼功能
-- 移植自 D:\project\AutoScript\SaoifAutoScript\tasks\Fishing\script_task.py
-- 设备分辨率 720x1280，横屏显示（rotate=1），脚本坐标基于横屏 1280x720
--
-- 性能说明：追踪阶段每次只取一列像素（1 次取像，本机约 50ms）直接找浮标颜色，
--           不做事件复核；状态判定把同一区域的 DO1/DO3/DO4 合并为一次取色。
-- 弹窗处理：主循环每轮优先调用 popup.checkLoginBonus()，命中随机弹窗
--           （如每日登录奖励）时处理完再继续钓鱼状态判定。
-- 参数覆盖：HIT_MARGIN/LEAD_* 等可在 cfg 里传入覆盖（用于批量对比实验），
--           不传时使用下方默认值。
--
-- 完美判定口径：提竿成功后仪表会"定格"，定格位置近似游戏判定时刻的浮标位置；
--               提竿后再取像两次读取该位置（两帧相同即定格），位置落在完美区域内
--               才计"完美区域命中"。
-- 提前量：实测取像到点击生效约 50~100ms，浮标速度 0.3~0.8px/ms，判定时浮标已
--         移动 20~60px，而完美区域约 19px 高 —— 必须提前出手。LEAD_MS 为初值，
--         运行中会按每次命中实测的延迟（定格位置-触发位置)/速度 做指数平滑自适应，
--         自动收敛到本机当前的实际延迟。
-- 提前量扫描（6 条鱼/组，leadMinV=0.1，hitMargin=0）：
--   无提前量：完美率 12%   lead50：36%   lead75：40%   lead100：7%   → 初值取 75

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
local HIT_MARGIN = 0      -- 浮标位置与完美区域边界的容差(px)；0=只有真正进入区域才提竿
local ZONE_MIN_H = 6      -- 完美区域最小高度(px)，过滤瞬时单像素误判
local TRACK_POLL_MS = 1200 -- 单次提竿追踪的最长时间(ms)，超时回主循环刷新状态
local LEAD_MIN_V = 0.1    -- 提前量预判阈值(px/ms)，低于该速度的浮标直接等进区
local LEAD_MS = 75        -- 提前量初值(ms)，运行中按实测延迟自适应微调
local LEAD_EMA = 0.3      -- 自适应平滑系数：新实测延迟占的比重
local LEAD_MIN_MS = 30    -- 自适应下限(ms)
local LEAD_MAX_MS = 150   -- 自适应上限(ms)
local LEAVE_WAIT_MS = 600 -- 提竿后等浮标离开窗口的上限(ms)，避免同一趟重复提竿
local VERIFY_BACK_MS = 60 -- 完美判定回推量(ms)：复核第一帧比点击时刻晚约这么多

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

-- 精准提竿：高频轮询浮标位置，进区立即提竿；快速浮标按速度预判提前出手
-- 方案取舍（实测于 Pixel 4 / SDK29）：
--   1) 事件触发后再截图复核：复核需要 50ms 量级，回来时浮标已越过边界 5~20px，
--      位置校验会把大量真实入区丢弃（浮标来回穿过却不提竿）；
--   2) 事件触发即提竿：完美区域出现/刷新时的自身动画同样会产生像素变化，
--      导致浮标还没进区就提前点击；
--   3) 本实现：每次只取一列像素直接找浮标颜色。慢速浮标（<LEAD_MIN_V）等它真正
--      进入区域才提竿；快速浮标按速度推算取像+点击延迟后的落点，落点在区域内
--      时提前出手。提前量 tune.leadMs 每次命中后按实测延迟自适应。
-- 单次最多追踪 TRACK_POLL_MS 后返回主循环，保证结算/弹窗等状态判定不被阻塞。
-- tune 为本次运行的调参状态 { leadMs = 毫秒 }
-- 返回：是否提竿, 触发时浮标位置, 是否提前量触发, 是否完美区域命中, 追踪耗时(ms)
local function tryPull(cfg, tune, ps, pe, needle)
    local hitMargin = cfg.hitMargin or HIT_MARGIN
    local leadMinV = cfg.leadMinV or LEAD_MIN_V
    local trackPollMs = cfg.trackPollMs or TRACK_POLL_MS
    local leaveWaitMs = cfg.leaveWaitMs or LEAVE_WAIT_MS
    local verifyBackMs = cfg.verifyBackMs or VERIFY_BACK_MS

    local t = tickCount()
    local deadline = t + trackPollMs
    local nd, ndT = needle, t
    local prevNd, prevT = nil, nil

    -- 提竿后的完美判定 + 提前量自适应
    -- 仪表在提竿成功后会"定格"，取像两次（两帧相同即定格）；
    -- 定格位置即判定时刻的浮标位置，用它判定是否算"完美区域命中"；
    -- 同时用（定格位置-触发位置)/速度 估算取像到判定生效的实际延迟，修正提前量。
    local function verifyAfterTap(vHint, nd0)
        local ps2, pe2, n2 = pixel.scanColumn(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
        local t2 = tickCount()
        local ps3, pe3, n3 = pixel.scanColumn(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
        local t3 = tickCount()
        local v = vHint
        if n2 and n3 and ps3 and t3 > t2 and n3 ~= n2 then
            v = (n3 - n2) / (t3 - t2) -- 未定格时用两帧复核速度更接近点击时刻
        elseif n2 and n3 and n3 == n2 then
            v = 0 -- 定格：位置即判定位置，无需回推
        end
        if not n2 or not ps2 then
            logger.debug(string.format("提竿复核: 区域=%d-%d 提竿后取像失败", ps, pe))
            return false
        end
        -- 自适应提前量：实测延迟 = 判定位置与触发取样位置的位移 / 速度
        if vHint and math.abs(vHint) >= 0.15 then
            local delay = (n2 - nd0) / vHint
            if delay > 15 and delay < 250 then
                local old = tune.leadMs
                tune.leadMs = old * (1 - LEAD_EMA) + delay * LEAD_EMA
                if tune.leadMs < LEAD_MIN_MS then tune.leadMs = LEAD_MIN_MS end
                if tune.leadMs > LEAD_MAX_MS then tune.leadMs = LEAD_MAX_MS end
                logger.debug(string.format("自适应提前量: 实测延迟=%.0fms %.0f→%.0fms",
                    delay, old, tune.leadMs))
            end
        end
        local posTap = n2 - (v or 0) * verifyBackMs
        local inZone = posTap >= ps2 and posTap <= pe2
        logger.debug(string.format("提竿复核: 区域=%d-%d 触发=%d v=%.2f 提竿后=%d 估算点击=%.0f 完美=%s",
            ps2, pe2, nd0, v or 0, n2, posTap, tostring(inZone)))
        return inZone
    end

    -- 等浮标离开提竿窗口，避免同一趟经过反复提竿
    local function waitLeave()
        local leaveEnd = tickCount() + leaveWaitMs
        while tickCount() < leaveEnd do
            local _, _, n = pixel.scanColumn(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
            if not n or n < ps - hitMargin or n > pe + hitMargin then
                break
            end
        end
    end

    while true do
        if nd and nd >= ps - hitMargin and nd <= pe + hitMargin then
            -- 取样时已在区域内（HIT_MARGIN=0 时即"真正进区"）→ 立即提竿
            local vHint = (prevNd and ndT > prevT) and (nd - prevNd) / (ndT - prevT) or nil
            doTap(cfg)
            local perfect = verifyAfterTap(vHint, nd)
            waitLeave()
            return true, nd, false, perfect, tickCount() - t
        end
        -- 快速浮标预判：按相邻两帧速度推算"取像+点击"延迟后的落点
        if nd and prevNd and ndT > prevT then
            local v = (nd - prevNd) / (ndT - prevT)
            if math.abs(v) >= leadMinV then
                local pred = nd + v * tune.leadMs
                if pred >= ps and pred <= pe then
                    logger.debug(string.format("预判提竿 v=%.2fpx/ms %d→%d 预测=%.0f 提前量=%.0fms 区域=%d-%d",
                        v, prevNd, nd, pred, tune.leadMs, ps, pe))
                    doTap(cfg)
                    local perfect = verifyAfterTap(v, nd)
                    waitLeave()
                    return true, nd, true, perfect, tickCount() - t
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
    local perfectCount = 0 -- 其中判定时刻仍在完美区域内的次数
    local hud = nil
    local hudText = ""
    local zoneMinH = cfg.zoneMinH or ZONE_MIN_H
    local tune = { leadMs = cfg.leadMs or LEAD_MS } -- 自适应提前量状态（每次运行从初值开始）

    local runStart = tickCount()

    -- HUD：钓鱼中/成功条数/平均每条耗时 + 命中次数/完美区域命中次数
    local function updateHud()
        if not cfg.showHud then return end
        local elapsedS = (tickCount() - runStart) / 1000
        local spd = successCount > 0 and math.floor(elapsedS / successCount + 0.5) or 0
        local text = string.format("钓鱼中 成功 %d 条  速度 %d 秒/条\n命中 %d 次  完美区域 %d 次  提前量 %dms",
            successCount, spd, hitCount, perfectCount, math.floor(tune.leadMs + 0.5))
        if text == hudText then return end
        hudText = text
        if not hud then hud = createHUD() end
        showHUD(hud, text, 14, "0xffffffff", "0xCC222222", 0, 20, 180, 360, 120)
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
    updateHud()

    while tickCount() < endTime do
        -- 优先处理随机弹窗（如每日登录奖励），处理完再继续本轮判定
        if popup.checkLoginBonus() then
            cloneSkip = 0
            zoneLogged = false
        end

        -- 状态检测：DO1/DO3/DO4 位于同一区域，合并为一次取色判定；TARGET 单独一次
        local st = pixel.matchStates({ DO1 = DO1, DO3 = DO3, DO4 = DO4 }, TOL, MATCH_RATE)
        local do1, do3Matched, do4 = st.DO1, st.DO3, st.DO4
        local textMatched = isMatch(TARGET)

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
                local hit, pos, lead, perfect, trackMs = tryPull(cfg, tune, pStart, pEnd, needle)
                if hit then
                    hitCount = hitCount + 1
                    if perfect then perfectCount = perfectCount + 1 end
                    local tag = perfect and "区域" or (lead and "提前量" or "点击时已出区")
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

        sleep(30)
    end

    if hud then
        hideHUD(hud)
        hud = nil
    end
    setSnapCacheTime(100)
    local elapsedS = (tickCount() - runStart) / 1000
    logger.info(string.format("统计: 成功=%d 命中=%d 完美区域=%d 完美率=%.0f%% 提前量=%.0fms 用时=%.0fs",
        successCount, hitCount, perfectCount,
        hitCount > 0 and perfectCount * 100 / hitCount or 0, tune.leadMs, elapsedS))
    logger.info(string.format("========== 结束，共钓鱼 %d 次 ==========", successCount))
end

dispatcher.register(M)

return M
