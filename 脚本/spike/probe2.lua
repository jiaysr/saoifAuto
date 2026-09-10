-- 脚本/spike/probe2.lua
-- 界面可行性验证（spike 分支）
--   验证「三标签页 + 固定行池动态列表 + 点击行进入任务配置页」能否构建
--
-- 依赖三个静态 UI API：
--   setUIText(handle, page, id, text)      把行按钮的文字换成任务名（按钮支持 setUIText）
--   setUIVisible(handle, page, id, 0/8)    0=显示，8=隐藏且不占位（多余行收起来）
--   onclick 事件的 arg2                    就是被点控件的 id，可反查行号

local logger = require("core.logger")

local ROWS = 8 -- 行池大小：XML 里预放 8 个按钮，运行时按需填充

-- 模拟任务清单（真实实现来自 tasks/index.lua + state.json）
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

local function run()
    local tasks = sampleTasks()
    local ovMap, allMap = {}, {} -- 行号 -> 任务（点击反查用）

    local function sortedEnabled()
        local list = {}
        for _, t in ipairs(tasks) do
            if t.enable then list[#list + 1] = t end
        end
        table.sort(list, function(a, b) return a.nextRun < b.nextRun end)
        return list
    end

    -- 固定行池填充：有数据就填文字+显示，没数据就清空+隐藏
    local function fill(handle, page, prefix, list, map)
        for i = 0, ROWS - 1 do
            local id = prefix .. tostring(i)
            local t = list[i + 1]
            if t then
                map[i] = t
                local tail = t.enable
                    and string.format("　下次 %s", os.date("%H:%M:%S", t.nextRun))
                    or "　（已禁用）"
                setUIText(handle, page, id, t.title .. tail)
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

    while true do
        rounds = rounds + 1
        if rounds > 8 then
            logger.warn("[界面探针] 循环超过 8 轮，强制结束")
            break
        end
        action = nil

        local function onEvent(handle, event, arg1, arg2)
            if event == "onload" then
                local en = sortedEnabled()
                fill(handle, 0, "btnRow", en, ovMap)
                fill(handle, 1, "btnAll", tasks, allMap)
                setUIText(handle, 0, "lblOvSummary",
                    string.format("共 %d 个任务，启用 %d 个", #tasks, #en))
                setUIText(handle, 0, "lblOvEmpty", #en == 0 and "没有启用的任务" or "")
                setUIText(handle, 1, "lblCfgSummary",
                    string.format("共 %d 个任务（含禁用）", #tasks))
                logger.info(string.format("[界面探针] 总览页填充 %d 行，配置页填充 %d 行", #en, #tasks))

            elseif event == "onclick" then
                local idx = tonumber(string.match(tostring(arg2), "^btnRow(%d+)$"))
                local which = "总览"
                if not idx then
                    idx = tonumber(string.match(tostring(arg2), "^btnAll(%d+)$"))
                    which = "配置"
                end
                if idx then
                    local map = (which == "总览") and ovMap or allMap
                    local t = map[idx]
                    logger.info(string.format("[界面探针] 点击 %s页 第 %d 行 (id=%s) -> 任务=%s",
                        which, idx, tostring(arg2), t and t.title or "nil"))
                    if t then
                        action = { kind = "open", task = t }
                        closeWindow(handle, true)
                    end
                else
                    logger.info("[界面探针] 点击了非行控件: " .. tostring(arg2))
                end

            elseif event == "onclose" then
                if not action then
                    action = { kind = arg1 and "run" or "quit" }
                end
                closeWindow(handle, arg1)
            end
        end

        logger.info(string.format(">>> 打开主界面（第 %d 轮）", rounds))
        showUI("spike_overview.ui", 640, 900, onEvent)
        logger.info(string.format("<<< 主界面关闭: action=%s", action and action.kind or "nil"))

        if not action or action.kind == "quit" then break end

        if action.kind == "open" then
            logger.info(string.format("[界面探针] 此处应打开该任务的配置页: %s -> 界面/tasks/%s.ui",
                action.task.title, action.task.name))
            toast("进入配置页：" .. action.task.title)
            sleep(600)
            -- 不 break：模拟"返回主界面"继续循环
        elseif action.kind == "run" then
            logger.info("[界面探针] 点击继续 -> 进入调度主循环（探针到此结束）")
            break
        end
    end
end

return { run = run }
