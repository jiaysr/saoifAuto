-- 脚本/tasks/fishing.lua
-- 自动钓鱼功能
-- 移植自 D:\project\AuotScript\SaoifAutoScript\tasks\Fishing\script_task.py
-- 坐标与特征色基于 1280x720 分辨率

local logger = require("core.logger")
local pixel = require("core.pixel")
local dispatcher = require("core.dispatcher")

local M = { name = "钓鱼" }

-- ============ 特征比色串（cmpColorEx 格式："x|y|BBGGRR-偏色,..."） ============
-- 颜色已从原 Python 特征库的 RRGGBB 转换为引擎的 BBGGRR，偏色 0F0F0F 对应原 tol=15
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

-- 浮标颜色 RGB(255,254,180)，需精确匹配
local NEEDLE_TIMEOUT = 6000   -- 等待浮标进入完美区域的最长时间(ms)
local CLONE_CONFIRM_FRAMES = 5 -- 连续 N 帧处于 DO3 状态判定为成功（替代原结算图判定）
local CLONE_IMG = "资源/fishing_clone.png" -- 可选结算图片，存在时成功后自动点击

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

-- 判断可选的结算图片是否存在
local function resolveCloneImg()
    local ok, exists = pcall(fileExist, CLONE_IMG)
    if ok and exists then
        return CLONE_IMG
    end
    return nil
end

function M.run(cfg)
    local str1, str3, str4, strT = DO1, DO3, DO4, TARGET

    local successCount = 0
    local hud = nil
    local cloneImg = resolveCloneImg()

    local function updateHud(state)
        if not cfg.showHud then return end
        if not hud then hud = createHUD() end
        showHUD(hud, string.format("钓鱼中 [%s]\n成功次数: %d", state, successCount),
            14, "0xffffffff", "0xCC222222", 0, 20, 180, 360, 120)
    end

    logger.info("=== 开始钓鱼 ===")
    logger.info(string.format("参数: 单轮超时=%ds 目标次数=%d 按钮=(%d,%d) 扫描列X=%d 区域Y=%d~%d",
        cfg.loopTime, cfg.maxCatch, cfg.clickX, cfg.clickY, cfg.scanX, cfg.zoneY1, cfg.zoneY2))
    if cloneImg then
        logger.info("已找到结算图片: " .. cloneImg)
    end

    -- 关闭截图缓存，保证浮标追踪时每次取到实时画面
    setSnapCacheTime(0)

    -- 首帧颜色采样调试（对应原 Python 的 _dump_colors）
    if cfg.debugColors then
        keepCapture()
        logger.info("首帧颜色采样:")
        pixel.dumpPoints(DO1, "DO1")
        pixel.dumpPoints(DO2, "DO2")
        pixel.dumpPoints(DO3, "DO3")
        pixel.dumpPoints(DO4, "DO4")
        pixel.dumpPoints(TARGET, "Target")
        releaseCapture()
    end

    local endTime = tickCount() + cfg.loopTime * 1000
    local cloneSkip = 0
    updateHud("待机")

    while tickCount() < endTime do
        -- 同一帧内完成多点状态判定，sim=0.6 对应原 Python 的 m >= n * 0.6
        keepCapture()
        local do1 = cmpColorEx(str1, 0.6) == 1
        local do4 = cmpColorEx(str4, 0.6) == 1
        local do3Matched = cmpColorEx(str3, 0.6) == 1
        local textMatched = cmpColorEx(strT, 0.6) == 1
        releaseCapture()

        -- 状态1：出现开始按钮
        if do1 then
            logger.info("点击开始")
            doTap(cfg)
            updateHud("抛竿")
        end

        -- 状态4：提竿时机
        if do4 then
            logger.info("提竿")
            doTap(cfg)
            updateHud("提竿")
        end

        -- 完美区域提示出现：追踪浮标并精准提竿
        if textMatched and not do3Matched then
            local pStart, pEnd = pixel.findPerfectZone(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
            if pStart then
                logger.info(string.format("完美区域: %d-%d", pStart, pEnd))
                updateHud("追踪浮标")
                local needleEnd = tickCount() + NEEDLE_TIMEOUT
                while tickCount() < needleEnd do
                    local pos = pixel.findNeedle(cfg.scanX, cfg.zoneY1, cfg.zoneY2)
                    if pos and pos >= pStart + 5 and pos <= pEnd + 5 then
                        logger.info(string.format("命中! pos=%d", pos))
                        doTap(cfg)
                        sleep(1000)
                        break
                    end
                    sleep(5)
                end
            end
        end

        -- DO3 状态持续出现（无文字提示）→ 判定钓鱼成功
        if not textMatched and do3Matched then
            cloneSkip = cloneSkip + 1
            if cloneSkip >= CLONE_CONFIRM_FRAMES then
                cloneSkip = 0
                successCount = successCount + 1
                logger.info(string.format("钓鱼成功! +1 (共 %d)", successCount))
                updateHud("结算")
                -- 若提供了结算图片资源则自动点击继续
                if cloneImg then
                    pcall(function()
                        local _, cx, cy = findPic(0, 0, 0, 0, cloneImg, "101010", 0, 0.8)
                        if cx and cx ~= -1 then
                            tap(cx, cy)
                        end
                    end)
                end
                endTime = tickCount() + cfg.loopTime * 1000
                sleep(1000)
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
