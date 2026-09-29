-- 脚本/tasks/minimap.lua
-- 小地图 / 大地图 识别调试功能
-- 循环识别并显示 HUD：
--   · 视野朝向(camera) → core.viewcone 自动模式(固定中心 / 全区域搜索) + 多帧投票 + conf 门限
--   · 角色朝向 → core.facing 旋转拼合图匹配 + core.facing_calib 标定成罗盘方位
--   · 图标/标记信息 → core.minimap
-- selfTest = true 时会依次把镜头转向 北/东/南/西 并核对视野识别结果。
local logger = require("core.logger")
local dispatcher = require("core.dispatcher")
local mm = require("core.minimap")
local vc = require("core.viewcone")
local fc = require("core.facing")

local M = { name = "小地图调试" }

local NL = string.char(10)   -- 换行符(避免源码里的转义写法)

local HUD_SIZE = 15
local HUD_X, HUD_Y = 20, 150
local HUD_W, HUD_H = 700, 330

function M.readConfig(handle)
    return {
        durationS = 30,
        intervalMs = 500,
        showHud = true,
        selfTest = false,
        debugScan = false,
        votes = 3,         -- 视野朝向投票帧数
        minConf = 0.85,    -- 单帧 conf 门限
        minVotes = 2,      -- 最少一致票数
        facing = true,     -- 是否显示角色朝向
        facingCalib = true,-- 是否套用已保存的角色朝向标定
        facingVotes = 1,   -- 角色朝向投票帧数(1=单帧)
    }
end

local function fmtYaw(yaw)
    if not yaw then return "--" end
    local dirs = { "北", "东北", "东", "东南", "南", "西南", "西", "西北" }
    local i = math.floor((yaw % 360) / 45 + 0.5) % 8 + 1
    return string.format("%.1f° %s", yaw, dirs[i])
end

local function fmtBlobs(blobs)
    if not blobs or #blobs == 0 then return "无" end
    local parts = {}
    for i = 1, math.min(#blobs, 4) do
        local b = blobs[i]
        parts[#parts + 1] = string.format("%s(%d) %s %.0fpx", b.cls, b.n, fmtYaw(b.bearing), b.dist)
    end
    return table.concat(parts, NL)
end

function M.run(cfg)
    logger.info("=== 小地图识别调试 ===")
    logger.info(string.format("参数: 时长=%ds 间隔=%dms HUD=%s 自检=%s 视野投票=%d帧 conf门限=%.2f 角色朝向=%s",
        cfg.durationS, cfg.intervalMs, tostring(cfg.showHud), tostring(cfg.selfTest), cfg.votes, cfg.minConf, tostring(cfg.facing)))

    if cfg.facing then
        if fc.ready() then
            logger.info("角色朝向拼合图已就绪")
        else
            logger.warn("角色朝向拼合图加载失败, 将跳过角色朝向")
            cfg.facing = false
        end
    end

    if cfg.facing and cfg.facingCalib then
        local okCal, cal = pcall(require, "core.facing_calib")
        if okCal and cal then
            local saved = cal.applySaved()
            logger.info("角色朝向标定: " .. string.format("%.1f", saved or fc.CALIB) .. "°  " .. cal.statusText())
        end
    end

    if cfg.debugScan then
        for _, l in ipairs(mm.debugScan(6)) do
            logger.debug("MM |" .. l .. "|")
        end
    end

    local r0 = mm.update()
    if not r0 or not r0.ok then
        logger.warn("未检测到小地图标记，请确认游戏处于可显示小地图的界面")
    else
        logger.info(string.format("初始识别: yaw=%s 标记=%d 锥=%d 图标=%d", fmtYaw(r0.yaw), r0.markerN, r0.coneN, #r0.blobs))
    end

    if cfg.selfTest then
        logger.info("---- 转向自检 ----")
        for _, target in ipairs({ 0, 90, 180, 270 }) do
            local diff = mm.turnTo(target)
            sleep(350)
            local r = mm.update()
            local err = (r and r.ok and r.yaw) and mm.diffTo180(r.yaw - target) or nil
            logger.info(string.format("目标 %d° → %s 误差=%s", target, fmtYaw(r and r.yaw), err and string.format("%.1f°", err) or "?"))
            sleep(300)
        end
    end

    local hud, hudText
    local endT = tickCount() + cfg.durationS * 1000
    local lastLog = 0
    local okN, failN, searchN, faceN = 0, 0, 0, 0

    while tickCount() < endT do
        local vote, verr = vc.detectAutoStable(cfg.votes, {
            minConf = cfg.minConf,
            minVotes = cfg.minVotes,
        })
        local r = mm.update()
        local text

        if vote and vote.bearing then
            if vote.mode == "big" then searchN = searchN + 1 else okN = okN + 1 end
            local where = string.format("%s 玩家=(%.0f,%.0f)",
                vote.mode == "big" and "搜索模式" or "固定中心", vote.x or 0, vote.y or 0)
            local voteTxt
            if vote.single then
                voteTxt = "单帧(票数不足)"
            else
                voteTxt = string.format("投票 %d 帧  一致率=%.0f%%  偏差=%.1f°",
                    vote.votes, (vote.agree or 0) * 100, vote.spread or 0)
            end
            text = "视野 = " .. fmtYaw(vote.bearing) .. NL
                .. where .. string.format("  conf=%.2f n=%d  ", vote.conf, vote.n or 0) .. voteTxt
        elseif vote then
            text = string.format("视野未识别（找到标记 (%.0f,%.0f) 但锥体太弱）", vote.x or 0, vote.y or 0)
        else
            failN = failN + 1
            text = "识别失败：" .. tostring(verr)
        end

        -- 角色朝向(精灵旋转角 → 标定后即罗盘方位)
        if cfg.facing and vote and vote.x then
            local f, ferr
            if (cfg.facingVotes or 1) > 1 then
                f, ferr = fc.detectStable(cfg.facingVotes, { x = vote.x, y = vote.y }, { minVotes = 2 })
            else
                f, ferr = fc.detect({ x = vote.x, y = vote.y })
            end
            if f and f.angle then
                faceN = faceN + 1
                local bush = fc.toBearing(f.angle)
                text = text .. NL .. string.format("角色 = %.1f° %s  sim=%.2f", bush, fc.text(bush), f.sim)
            elseif f then
                text = text .. NL .. string.format("角色 = 未识别  sim=%.2f", f.sim)
            else
                text = text .. NL .. "角色 = " .. tostring(ferr)
            end
        end

        text = text .. NL .. "图标 " .. fmtBlobs(r and r.blobs)

        if cfg.showHud and text ~= hudText then
            hudText = text
            if not hud then hud = createHUD() end
            showHUD(hud, text, HUD_SIZE, "0xffffffff", "0xCC222222", 0, HUD_X, HUD_Y, HUD_W, HUD_H)
        end

        if tickCount() - lastLog >= 2000 then
            lastLog = tickCount()
            logger.info(string.format("%s yaw=%s pos=(%.0f,%.0f) votes=%d conf=%.2f | 角色帧=%d 标定=%.1f",
                (vote and vote.mode == "big") and "SEARCH" or "CENTER",
                fmtYaw(vote and vote.bearing), (vote and vote.x) or 0, (vote and vote.y) or 0,
                (vote and vote.votes) or 0, (vote and vote.conf) or 0, faceN, fc.CALIB))
        end
        sleep(cfg.intervalMs)
    end

    if hud then hideHUD(hud) end
    logger.info(string.format("===== 结束: 中心模式 %d / 搜索模式 %d / 角色朝向成功 %d / 失败 %d =====", okN, searchN, faceN, failN))
end

dispatcher.register(M)

return M
