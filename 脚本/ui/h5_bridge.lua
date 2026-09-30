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

    -- 会话校验：忽略上一次运行残留页面发来的消息（它们仍会触发定时器等）
    if t ~= "ready" and tostring(msg.sid or "") ~= c.sid then
        logger.debug("[H5] 忽略非本会话消息: " .. t)
        return
    end

    if t == "ready" then
        if not c.ready then c.ready = true end
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
        c.action = "cancel"

    elseif t == "ping" then
        send({ type = "pong", data = {
            t = msg.t,
            luaTime = os.date("%H:%M:%S"),
            func = tostring(c.values.func or "-"),
            loopTime = tostring(c.values.loopTime or "-"),
        } })

    elseif t == "jserror" then
        logger.error("[H5] 页面 JS 报错: " .. tostring(msg.text))
    end
end

function _G.__h5_onClose()
    -- 旋转适配会主动 dismiss 再重建，此时不算"被外部关闭"
    if ctx and not ctx.rebuilding then
        logger.info("[H5] 窗口被外部关闭")
        ctx.action = "cancel"
    end
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

    -- 按当前屏幕方向计算 WebView 尺寸
    local function calcSize()
        local dw, dh = getDisplaySize()
        -- getDisplaySize 返回未旋转的原始分辨率：横屏（旋转 90/270 度）时当前屏幕高是短边，需交换
        local rot = tonumber(getDisplayRotate()) or 0
        if rot % 2 ~= 0 then dw, dh = dh, dw end
        local w = math.min((tonumber(dw) or 1280) - 80, 1100)
        -- 高度必须给显式像素值：引擎把布局包在 ScrollView 里，高度传 -1（填满）会塌缩成自适应内容
        local h = (tonumber(dh) or 720) - 130
        if w < 640 then w = 640 end
        if h < 400 then h = 400 end
        return w, h
    end

    local wvW, wvH = calcSize()

    -- 每次运行使用唯一的窗口/控件名：避免上次运行残留的窗口/WebView 造成消息串台
    -- （布局名同时是悬浮窗标题，因此用可读标题 + 唯一后缀）
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
        rebuilding = false,
    }
    warned = {}

    -- 创建（或旋转后重建）悬浮窗：布局填满屏幕，WebView 宽度填满、高度用显式像素值
    local function buildWindow()
        if not ui.newLayout(WINDOW, -1, -1) then
            logger.error("[H5] newLayout 失败")
            return false
        end
        if not ui.addWebView(WINDOW, WEB, "file://" .. htmlPath, -1, wvH) then
            logger.error("[H5] addWebView 失败")
            ui.dismiss(WINDOW)
            return false
        end
        ui.setOnClose(WINDOW, "__h5_onClose()")
        if not ui.show(WINDOW, false) then
            logger.error("[H5] 界面显示失败")
            return false
        end
        logger.info(string.format("[H5] 界面已显示（WebView %dx%d）", wvW, wvH))
        return true
    end

    if not buildWindow() then
        ctx = nil
        return nil
    end

    -- 等待用户操作；页面迟迟不就绪则超时退出，避免无人值守卡死
    local startT = tickCount()
    local warnedLate = false
    local lastRot = tonumber(getDisplayRotate()) or 0

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

        -- 屏幕方向变化检测：重建窗口以适配新的可视区高度。
        -- 已填写的参数都在 ctx.values 里，新页面 ready 后会原样重发，用户无感知。
        local okR, curRot = pcall(getDisplayRotate)
        curRot = (okR and tonumber(curRot)) or lastRot
        if curRot % 2 ~= lastRot % 2 then
            logger.info(string.format("[H5] 屏幕方向变化（rot %d -> %d），重建界面适配", lastRot, curRot))
            lastRot = curRot
            ctx.rebuilding = true
            ui.dismiss(WINDOW)
            ctx.rebuilding = false
            ctx.ready = false
            ctx.acked = false
            ctx.ackGaveUp = nil
            ctx.initTries = 0
            wvW, wvH = calcSize()
            if not buildWindow() then
                ctx.action = "cancel"
                break
            end
            -- 就绪超时从重建时刻重新计时
            startT = tickCount()
            warnedLate = false
        end
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
