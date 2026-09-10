-- 脚本/spike/probe4.lua
-- 补两个未验证的环节：
--   A) 配置保存后，同一轮运行内 getUIConfig 能否立刻读到新值
--      （决定「改完任务配置 → 回到总览页是否立刻变化」）
--   B) 点击任务行，真的打开该任务的配置页并返回主界面
--      （probe2 只做了点击映射，没真开窗口）

local logger = require("core.logger")

local ROWS = 8

local function sampleTasks()
    local now = os.time()
    return {
        { name = "fishing",  title = "钓鱼",     enable = true,  nextRun = now + 120 },
        { name = "daily",    title = "每日任务", enable = true,  nextRun = now + 25 },
        { name = "board",    title = "公告板",   enable = true,  nextRun = now + 3600 },
        { name = "activity", title = "活动",     enable = true,  nextRun = now + 600 },
        { name = "guild",    title = "公会活动", enable = false, nextRun = now + 60 },
        { name = "shop",     title = "商店",     enable = true,  nextRun = now + 1800 },
    }
end

local function readCfg(name, page, id)
    local raw = getUIConfig(name)
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, t = pcall(jsonLib.decode, raw)
    if not ok or type(t) ~= "table" then return nil end
    local p = t["page" .. tostring(page)] or {}
    return p[id]
end

-- ===== 阶段 A：写后即时读 =====
local function phaseA()
    logger.info("========== A: 配置写后即时读 ==========")

    local marker = "即时" .. tostring(tickCount())
    local json = string.format('{"page0":{"edNum":"%s"}}', marker)

    setUIConfig("spike_probe.config", json)
    local got = readCfg("spike_probe.config", 0, "edNum")
    logger.info(string.format("[A1] setUIConfig 后读回 = %s（期望 %s）", tostring(got), marker))
    logger.info("[A1] " .. (got == marker and "通过：同轮写后立即可读" or "未通过"))

    -- 真实任务配置名是否可用
    setUIConfig("tasks_fishing.config", json)
    local got2 = readCfg("tasks_fishing.config", 0, "edNum")
    logger.info(string.format("[A2] tasks_fishing.config 写后读回 = %s", tostring(got2)))
    logger.info("[A2] " .. (got2 == marker and "通过：任务配置名格式可用" or "未通过"))
end

-- ===== 阶段 B：点击行 -> 真的打开任务配置页 -> 返回 =====
local function phaseB()
    logger.info("========== B: 点击行真的打开配置页 ==========")

    local tasks = sampleTasks()
    local ovMap, allMap = {}, {}

    local function sorted()
        local l = {}
        for _, t in ipairs(tasks) do
            if t.enable then l[#l + 1] = t end
        end
        table.sort(l, function(a, b) return a.nextRun < b.nextRun end)
        return l
    end

    local function fill(handle, page, prefix, list, map)
        for i = 0, ROWS - 1 do
            local id = prefix .. tostring(i)
            local t = list[i + 1]
            if t then
                map[i] = t
                setUIText(handle, page, id, string.format("%s　下次 %s",
                    t.title, os.date("%H:%M:%S", t.nextRun)))
                setUIVisible(handle, page, id, 0)
            else
                map[i] = nil
                setUIText(handle, page, id, "")
                setUIVisible(handle, page, id, 8)
            end
        end
    end

    local action
    local rounds = 0

    while rounds < 6 do
        rounds = rounds + 1
        action = nil

        local function onEvent(handle, event, arg1, arg2)
            if event == "onload" then
                fill(handle, 0, "btnRow", sorted(), ovMap)
                fill(handle, 1, "btnAll", tasks, allMap)
                setUIText(handle, 0, "lblOvSummary",
                    string.format("共 %d 个任务，启用 %d 个", #tasks, #sorted()))
                setUIText(handle, 1, "lblCfgSummary",
                    string.format("共 %d 个任务（含禁用）", #tasks))
            elseif event == "onclick" then
                local idx, prefix
                for _, p in ipairs({ "btnRow", "btnAll" }) do
                    local n = tonumber(string.match(tostring(arg2), "^" .. p .. "(%d+)$"))
                    if n then idx, prefix = n, p; break end
                end
                if idx then
                    local t = (prefix == "btnRow") and ovMap[idx] or allMap[idx]
                    logger.info(string.format("[B] 点击 %s 第 %d 行 -> 任务 %s",
                        prefix, idx, t and t.title or "nil"))
                    if t then
                        action = { kind = "open", task = t }
                        closeWindow(handle, true)
                    end
                end
            elseif event == "onclose" then
                action = action or { kind = arg1 and "run" or "quit" }
                closeWindow(handle, arg1)
            end
        end

        logger.info(">>> [B] 打开主界面（第 " .. rounds .. " 轮）")
        showUI("spike_overview.ui", 640, 900, onEvent)

        if not action or action.kind == "quit" or action.kind == "run" then
            logger.info("[B] 主界面结束: " .. (action and action.kind or "nil"))
            break
        end

        if action.kind == "open" then
            logger.info("[B] 真的打开任务配置页: " .. action.task.title)
            local closed = false
            local function onTaskEvent(handle, event, arg1)
                if event == "onclose" then
                    closed = true
                    closeWindow(handle, arg1)
                end
            end
            -- 用 spike_config.ui 充当「该任务的配置页」
            showUI("spike_config.ui", 560, 720, onTaskEvent)
            logger.info("[B] 任务配置页已关闭(closed=" .. tostring(closed) .. ")，返回主界面")
        end
    end
end

local function run()
    phaseA()
    phaseB()
    logger.info("========== 探针结束 ==========")
end

return { run = run }
