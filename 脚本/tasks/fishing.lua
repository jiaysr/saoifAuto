-- 脚本/tasks/fishing.lua
-- 自动钓鱼功能
-- 移植自 D:\project\AutoScript\SaoifAutoScript\tasks\Fishing\script_task.py
-- 设备分辨率 720x1280，横屏显示（rotate=1），脚本坐标基于横屏 1280x720
--
-- 性能说明：追踪阶段不轮询浮标位置，而是用 isDisplayDead 在原生层等待
--           完美区域像素变化（浮标进入即变色），Lua 侧几乎零开销；
--           状态判定把同一区域的 DO1/DO3/DO4 合并为一次取色。

local logger = require("core.logger")
local pixel = require("core.pixel")
local dispatcher = require("core.dispatcher")

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
local DEAD_WAIT = 1      -- isDisplayDead 单次阻塞上限(秒)，期间区域变色立即返回
local ZONE_PAD_X = 2     -- 监视区域相对扫描列左右的扩展(px)
local HIT_MARGIN = 6     -- 浮标位置与完美区域边界的容差(px)
local ZONE_MIN_H = 6     -- 完美区域最小高度(px)，过滤瞬时单像素误判

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

-- 精准提竿：isDisplayDead 事件驱动 + 位置复核
-- 原理：浮标进入完美区域时，区域内像素被浮标覆盖而发生变化，isDisplayDead 阻塞等待
--       该变化并立即返回（原生层等待，Lua 侧没有轮询循环，不会持续取像掉帧）；
--       变化后用 scanColumn 复核浮标位置，避免浮标离开/区域消失造成的误触。
-- 入参 needle 为本次已取到的浮标位置（nil 表示当前不在扫描列内）
-- 返回：是否提竿, 浮标位置, 事件到提竿的耗时(ms)
local function tryPull(cfg, ps, pe, needle)
    local pos, delayMs
    if needle and needle >= ps - HIT_MARGIN and needle <= pe + HIT_MARGIN then
        -- 快速通道：浮标已在区域内，直接提竿
        pos, delayMs = needle, 0
    else
        local t = tickCount()
        -- 阻塞等待完美区域像素变化，浮标一进入立即返回
        if isDisplayDead(cfg.scanX - ZONE_PAD_X, ps, cfg.scanX + ZONE_PAD_X, pe, DEAD_WAIT) then
            return false
        end
        -- 复核：变化后浮标确实在区域内才提竿
        local _, _, n2 = pixel.scanColumn(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
        delayMs = tickCount() - t
        if not (n2 and n2 >= ps - HIT_MARGIN and n2 <= pe + HIT_MARGIN) then
            return false
        end
        pos = n2
    end

    doTap(cfg)
    -- 浮标离开同样是区域变色事件：再等一次，避免同一次经过反复提竿
    isDisplayDead(cfg.scanX - ZONE_PAD_X, ps, cfg.scanX + ZONE_PAD_X, pe, DEAD_WAIT)
    return true, pos, delayMs
end

function M.run(cfg)
    local successCount = 0
    local hitCount = 0
    local hud = nil
    local hudText = ""

    local function updateHud(state)
        if not cfg.showHud then return end
        local text = string.format("钓鱼中 [%s]\n成功: %d  命中: %d", state, successCount, hitCount)
        if text == hudText then return end
        hudText = text
        if not hud then hud = createHUD() end
        showHUD(hud, text, 14, "0xffffffff", "0xCC222222", 0, 20, 180, 360, 120)
    end

    logger.info("=== 开始钓鱼 ===")
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
    updateHud("待机")

    while tickCount() < endTime do
        -- 状态检测：DO1/DO3/DO4 位于同一区域，合并为一次取色判定；TARGET 单独一次
        local st = pixel.matchStates({ DO1 = DO1, DO3 = DO3, DO4 = DO4 }, TOL, MATCH_RATE)
        local do1, do3Matched, do4 = st.DO1, st.DO3, st.DO4
        local textMatched = isMatch(TARGET)

        -- 状态1：出现开始按钮
        if do1 then
            logger.info("点击开始")
            doTap(cfg)
            zoneLogged = false
            updateHud("抛竿")
        end

        -- 状态4：提竿时机
        if do4 then
            logger.info("提竿")
            doTap(cfg)
            updateHud("提竿")
        end

        -- 完美区域提示出现：isDisplayDead 检测区域变色（浮标进入）→ 精准提竿
        if textMatched and not do3Matched then
            local pStart, pEnd, needle = pixel.scanColumn(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
            -- 完美区域高度至少 ZONE_MIN_H，过滤瞬时出现的单像素误判
            if pStart and (pEnd - pStart) >= ZONE_MIN_H then
                if not zoneLogged then
                    logger.info(string.format("完美区域: %d-%d", pStart, pEnd))
                    zoneLogged = true
                end
                updateHud("追踪浮标")
                local hit, pos, delayMs = tryPull(cfg, pStart, pEnd, needle)
                if hit then
                    hitCount = hitCount + 1
                    logger.info(string.format("命中! pos=%d 区域=%d-%d 反应=%dms",
                        pos, pStart, pEnd, delayMs))
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
                    updateHud("结算")
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
    logger.info(string.format("========== 结束，共钓鱼 %d 次 ==========", successCount))
end

dispatcher.register(M)

return M
