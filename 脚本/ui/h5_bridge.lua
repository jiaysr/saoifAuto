-- 脚本/ui/h5_bridge.lua
-- H5(WebView) 界面桥：窗口管理 + Lua <-> JS 变量通道（Base64(JSON) 协议）
--
--   JS  -> Lua : window.bridge.callLua("__h5_onMessage('<base64>')")
--                 消息: ready / change / submit / cancel / ping
--   Lua -> JS : ui.callJs(web, "javascript:APP.recv('<base64>')")
--                 消息: init / hint / error / pong
--
-- 页面源码在 界面/saoif_h5.html，经生成脚本内嵌到 脚本/ui/h5_page.lua
-- （项目文件在设备运行时不可读，页面必须内嵌后写入 sdcard 再由 WebView 加载）

local logger = require("core.logger")
local page = require("ui.h5_page")

local M = {}

-- 当前会话的窗口/控件名（每次运行生成唯一后缀，避免与上次残留的窗口串台）
local WINDOW = "saoif_h5"
local WEB = "web"

local HTML_NAME = "saoif_h5_page.html"
local SAVE_FILE = "saoif_h5_config.json"
local READY_TIMEOUT_MS = 60000

local ctx = nil   -- 当前会话状态
local warned = {} -- 已提示过越界的字段

-- ============ 协议编解码 ============

local function encodeMsg(tbl)
    local ok, data = pcall(function()
        return encodeBase64(jsonLib.encode(tbl))
    end)
    if not ok or type(data) ~= "string" or #data == 0 then
        logger.error("[H5] 消息编码失败: " .. tostring(data))
        return nil
    end
    -- 去掉可能的换行/空白（部分 base64 实现会按 76 字符折行，注入 JS 字符串会失效）
    data = data:gsub("[%s]", "")
    return data
end

local function decodeMsg(raw)
    local ok, json = pcall(decodeBase64, raw)
    if not ok then return nil, "base64 解码失败" end
    local ok2, tb = pcall(jsonLib.decode, json)
    if not ok2 or type(tb) ~= "table" then return nil, "json 解析失败: " .. tostring(tb) end
    return tb
end

-- Lua -> JS 下发消息
local function send(tbl)
    local data = encodeMsg(tbl)
    if not data then return false end
    local r = ui.callJs(WEB, "javascript:APP.recv('" .. data .. "')")
    if not r then logger.warn("[H5] 下发失败: " .. tostring(tbl.type)) end
    return r
end
M.send = send

-- ============ 实时校验（change 消息触发，越界推 hint） ============

local RANGES = {
    loopTime = { 5, 3600, "单轮超时" },
    maxCatch = { 0, 9999, "目标次数" },
    clickX   = { 0, 1280, "按钮 X" },
    clickY   = { 0, 720,  "按钮 Y" },
    scanX    = { 0, 1280, "扫描列 X" },
    zoneY1   = { 0, 720,  "扫描区 Y1" },
    zoneY2   = { 0, 720,  "扫描区 Y2" },
}

local function liveCheck(key, value)
    local r = RANGES[key]
    if not r then return end
    local n = tonumber(value)
    if n and (n < r[1] or n > r[2]) then
        if not warned[key] then
            warned[key] = true
            local text = string.format("%s 建议范围 %d ~ %d，当前 %s", r[3], r[1], r[2], tostring(value))
            logger.debug("[H5] 实时提示: " .. text)
            send({ type = "hint", data = { level = "warn", text = text } })
        end
    elseif warned[key] then
        warned[key] = nil
        logger.debug("[H5] 实时提示: " .. key .. " 已回到建议范围")
        send({ type = "hint", data = { level = "ok", text = "参数已修正" } })
    end
end

-- 下发/重发初值（页面确认 ack 前会重发，以防 WebView 重建页面实例导致丢失）
local function pushInit(c)
    c.initSentAt = tickCount()
    c.initTries = (c.initTries or 0) + 1
    send({ type = "init", data = { ver = c.ver, sid = c.sid, tasks = c.tasks, configs = c.configs or {}, values = c.values } })
end

-- ============ JS -> Lua 入口 ============

function _G.__h5_onMessage(raw)
    local msg, err = decodeMsg(tostring(raw))
    if not msg then
        logger.error("[H5] 消息解析失败: " .. tostring(err))
        return
    end
    local c = ctx
    if not c then return end

    local t = tostring(msg.type)
    -- 入站留痕（限量，防风暴刷屏）+ 限流：
    -- 页面/残留 WebView 实例异常时会疯狂重发 ready，导致 ready→init→ack 风暴
    -- （现象：日志里"初值已应用（第 1209 次下发）"，设备被拖死、窗口一闪而过）
    c.recvN = (c.recvN or 0) + 1
    if c.recvN <= 30 then logger.info("[H5] recv: " .. t .. " sid=" .. tostring(msg.sid)) end
    local nowT = tickCount()
    if not c.rateAt or nowT - c.rateAt >= 1000 then
        c.rateAt, c.rateN = nowT, (c.rateN or 0) + 1
    else
        c.rateN = (c.rateN or 0) + 1
        if c.rateN > 40 then
            if not c.rateWarned then
                c.rateWarned = true
                logger.warn("[H5] 入站报文速率异常（>40/秒），进入限流：只放行 ack/submit/cancel")
            end
            if t ~= "ack" and t ~= "submit" and t ~= "cancel" then return end
        end
    end

    -- 会话校验：忽略上一次运行残留页面发来的消息（它们仍会触发定时器等）
    if t ~= "ready" and t ~= "diag" and tostring(msg.sid or "") ~= c.sid then
        logger.info("[H5] 忽略非本会话消息: " .. t .. " sid=" .. tostring(msg.sid) .. " 当前=" .. tostring(c.sid))
        return
    end

    if t == "ready" then
        if c.ready then
            -- 重复 ready（页面被重建/残留实例）只登记不处理，否则 init 无上限重发
            c.dupReady = (c.dupReady or 0) + 1
            if c.dupReady <= 5 then logger.warn("[H5] 重复 ready 已忽略（第 " .. c.dupReady .. " 次）") end
            return
        end
        c.ready = true
        logger.info("[H5] 页面就绪，下发功能列表与初值")
        -- 短报文探针：确认 callJs 能到达当前活动的 WebView 实例
        local pok = ui.callJs(WEB, "javascript:APP.probe('ready" .. tostring(c.initTries or 0) .. "','" .. c.sid .. "')")
        if not pok then logger.warn("[H5] 探针下发失败") end
        pushInit(c)

    elseif t == "probe" then
        logger.info("[H5] 探针回应: " .. tostring(msg.text))

    elseif t == "ack" then
        c.acked = true
        c.ackedAt = tickCount()
        logger.info(string.format("[H5] 初值已应用（第 %d 次下发）", c.initTries or 1))

    elseif t == "change" then
        c.values[msg.key] = msg.value
        logger.debug(string.format("[H5] 变量变化 %s = %s", tostring(msg.key), tostring(msg.value)))
        liveCheck(msg.key, msg.value)

    elseif t == "submit" then
        local cfg = msg.data or c.values
        local ok, errmsg = true, nil
        if c.validate then ok, errmsg = c.validate(cfg) end
        if ok then
            c.action, c.result = "submit", cfg
        else
            logger.warn("[H5] 提交被拒绝: " .. tostring(errmsg))
            send({ type = "error", data = { text = tostring(errmsg or "参数校验失败") } })
        end

    elseif t == "cancel" then
        -- 正常取消路径：用户点两次"退出"（页面必然已就绪并 ack）。
        -- 页面未 ack 前收到的 cancel 一律视为幽灵消息（残留页面 / WebView 复用时序 / 误触），
        -- 否则真机会出现"窗口一闪而过"。窗口被系统关闭走 __h5_onClose，不受此限制。
        if c.acked and (tickCount() - (c.shownAt or 0) >= 1200) then
            c.action = "cancel"
        else
            c.earlyCancels = (c.earlyCancels or 0) + 1
            logger.warn(string.format("[H5] 忽略过早 cancel（页面未 ack），第 %d 次；sid=%s", c.earlyCancels, tostring(msg.sid)))
        end

    elseif t == "ping" then
        send({ type = "pong", data = {
            t = msg.t,
            luaTime = os.date("%H:%M:%S"),
            func = tostring(c.values.func or "-"),
            loopTime = tostring(c.values.loopTime or "-"),
        } })

    elseif t == "diag" then
        logger.info("[H5][diag] " .. tostring(msg.text))

    elseif t == "jserror" then
        logger.error("[H5] 页面 JS 报错: " .. tostring(msg.text))
    end
end

function _G.__h5_onClose()
    logger.info("[H5] 窗口被外部关闭（ctx=" .. tostring(ctx ~= nil) .. "）")
    if ctx then ctx.action = "cancel" end
end

-- ============ 配置持久化 ============

function M.loadSaved()
    local path = tostring(getSdPath()) .. "/" .. SAVE_FILE
    local ok, content = pcall(readFile, path)
    if not ok or type(content) ~= "string" or #content == 0 then return nil end
    local ok2, tb = pcall(jsonLib.decode, content)
    if ok2 and type(tb) == "table" then return tb end
    return nil
end

function M.save(cfg)
    local path = tostring(getSdPath()) .. "/" .. SAVE_FILE
    local ok, data = pcall(jsonLib.encode, cfg)
    if not ok then
        logger.warn("[H5] 配置序列化失败")
        return false
    end
    local w = writeFile(path, data)
    logger.info("[H5] 配置已保存: " .. path .. " => " .. tostring(w))
    return w
end

-- ============ 显示界面并等待用户操作 ============
-- opts = { ver, tasks, values, validate(cfg)->ok,errmsg }
-- 返回: 配置表（点击保存并运行）或 nil（退出/关闭/加载失败）
function M.open(opts)
    local sd = tostring(getSdPath())
    local htmlPath = sd .. "/" .. HTML_NAME
    if not writeFile(htmlPath, page.html) then
        logger.error("[H5] 页面写入失败: " .. htmlPath)
        return nil
    end
    logger.info(string.format("[H5] 页面已写入 %s（%d 字节）", htmlPath, #page.html))

    -- 每会话唯一标签：窗口/控件名唯一，避免上次运行的残留窗口与 WebView 消息串台
    -- （⚠ 这段曾在"两套尺寸"补丁里被整段误删，导致 ctx=nil → 等待循环不跑 → 界面一闪而过）
    local tag = tostring(tickCount() % 1000000)
    WINDOW = "SAOIF 自动助手#" .. tag
    WEB = "web_" .. tag
    logger.info(string.format("[H5] 本次会话 窗口=%s 控件=%s", WINDOW, WEB))

    ctx = {
        ver = opts.ver or "1.0",
        sid = "sid" .. tag,
        tasks = opts.tasks or {},
        configs = opts.configs or {},
        values = opts.values or {},
        validate = opts.validate,
        autoTest = opts.autoTest and true or false,
        autoFired = false,
        acked = false,
        ackedAt = 0,
        initSentAt = 0,
        initTries = 0,
        action = nil,
        result = nil,
        ready = false,
    }
    warned = {}

    -- 屏幕尺寸：getDisplaySize() 的返回顺序不随横竖屏变化（实测横屏游戏下返回竖屏尺寸 720x1280），
    -- 直接用会算出"高过屏幕"的窗口 → 底部按钮被裁掉且无法滚动（横屏无法滚动问题的根因）。
    -- 本游戏恒为横屏，故取 max 为宽、min 为高。
            -- ==================== 两套固定尺寸（UI 只按这两种尺寸维护样式） ====================
    -- ⚠ 本环境（云机/模拟器）getDisplaySize() 与 getDisplayRotate() 都不随姿态变化：
    --    实测横屏游戏下 getDisplaySize 仍返回 720x1280、getDisplayRotate 恒为竖屏值，
    --    照它判断会把竖屏尺寸(640x980)套到 720 高的横屏上 → 窗口被系统直接关掉。
    --    因此姿态改用常量指定：默认 landscape（游戏常态）；要在竖屏下调试就改成 "portrait"。
    -- 尺寸策略 auto：本环境无法感知姿态（getDisplaySize/getDisplayRotate 恒返回竖屏值 720x1280），
    -- 所以默认取"横竖屏都装得下"的尺寸：宽 ≤ min(屏幕宽高)-80，高 ≤ min(屏幕宽高)-120。
    -- 血泪教训：窗口一旦超出屏幕（横屏套竖屏尺寸 / 竖屏套横屏尺寸），触摸会被吃掉 → 完全无法滚动。
    -- 需要强制某一套时改 ORIENT："landscape"(1100x570) / "portrait"(640x980)，仍会做装得下的硬兜底。
    local ORIENT = "auto"               -- "auto" | "landscape" | "portrait"
    local sw, sh = getDisplaySize()
    sw = tonumber(sw) or 720
    sh = tonumber(sh) or 1280
    local small = math.min(sw, sh)
    local wvW, wvH
    if ORIENT == "landscape" then
        wvW, wvH = 1100, 570
    elseif ORIENT == "portrait" then
        wvW, wvH = 640, 980
    else
        wvW = math.min(1100, small - 80)   -- 720 -> 640
        wvH = math.min(620, small - 120)   -- 720 -> 600
    end
    -- 硬兜底：任何模式下都不允许超出当次可用范围
    if wvW > small - 40 then wvW = small - 40 end
    if wvH > small - 120 then wvH = small - 120 end
    logger.info(string.format("[H5] 窗口尺寸策略 %s -> %dx%d（屏幕 %dx%d）", ORIENT, wvW, wvH, sw, sh))

local layW, layH = wvW + 40, wvH + 100
    if not ui.newLayout(WINDOW, layW, layH) then
        logger.error("[H5] newLayout 失败")
        ctx = nil
        return nil
    end
    if not ui.addWebView(WINDOW, WEB, "file://" .. htmlPath, wvW, wvH) then
        logger.error("[H5] addWebView 失败")
        ui.dismiss(WINDOW)
        ctx = nil
        return nil
    end
    ui.setOnClose(WINDOW, "__h5_onClose()")
    if not ui.show(WINDOW, false) then
        logger.error("[H5] 界面显示失败")
        ctx = nil
        return nil
    end
    logger.info(string.format("[H5] 界面已显示（WebView %dx%d）", wvW, wvH))
    ctx.shownAt = tickCount()

    -- 等待用户操作；页面迟迟不就绪则超时退出，避免无人值守卡死
    local startT = tickCount()
    local warnedLate = false
    while ctx and not ctx.action do
        local elapsed = tickCount() - startT
        -- init 未确认前重发（页面可能被 WebView 重建，导致首次初值丢失）
        if ctx.ready and not ctx.acked and tickCount() - ctx.initSentAt > 1500 then
            if (ctx.initTries or 0) < 8 then
                pushInit(ctx)
                if ctx.initTries == 3 then
                    logger.warn("[H5] 初值下发多次未确认，继续重试…")
                end
            elseif not ctx.ackGaveUp then
                ctx.ackGaveUp = true
                logger.error("[H5] 初值下发失败（页面未确认），界面可能不可用")
            end
        end
        -- 自检模式：初值应用并渲染稳定后，自动改参数并点击"保存并运行"
        if ctx.autoTest and ctx.acked and not ctx.autoFired and tickCount() - ctx.ackedAt > 3000 then
            ctx.autoFired = true
            logger.info("[H5] 自检模式：触发页面自动提交")
            local ok = ui.callJs(WEB, "javascript:APP.autoTest()")
            logger.info("[H5] 自检 callJs => " .. tostring(ok))
        end
        if elapsed > READY_TIMEOUT_MS and not ctx.ready then
            logger.error("[H5] 页面未就绪，超时退出（可能是 WebView 加载失败）")
            toast("H5 界面加载失败，请查看日志")
            break
        end
        if not warnedLate and elapsed > 20000 and not ctx.ready then
            warnedLate = true
            logger.warn("[H5] 页面 20 秒仍未就绪，继续等待…")
        end
        sleep(200)
    end

    local action, result = "cancel", nil
    if ctx then
        action = ctx.action or "cancel"
        result = ctx.result
    end
    ctx = nil

    ui.dismiss(WINDOW)
    logger.info("[H5] 界面已关闭，用户操作: " .. tostring(action))
    if action == "submit" then return result end
    return nil
end

return M
