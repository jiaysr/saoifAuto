-- 脚本/spike/probe.lua
-- 框架设计假设验证探针（spike/framework-skeleton 分支专用，验证完即删）
--
-- 目的：在真机上确认框架设计依赖的 5 个 lrjl 行为，避免架构建立在错误假设上。
--   ① getWorkPath 可写 + jsonLib 读写状态文件
--   ② 窗口"配置文件"属性自动保存 / 回填控件值
--   ③ showUI 阻塞 + upvalue 传 action，可实现窗口循环
--   ④ require 多级模块路径可用
--   ⑤ 到期调度器原型能选出最早到期的启用任务

local logger = require("core.logger")
local dummy = require("spike.lib.dummy") -- 同时验证 ④

local _M = {}

local results = {}

local function check(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok and true or false }
    logger.info(string.format("[探针]%s %s%s",
        ok and "通过" or "失败", name,
        detail ~= nil and ("  <" .. tostring(detail) .. ">") or ""))
end

-- ④ 多级 require
local function probeRequire()
    check("require 多级路径 spike.lib.dummy",
        type(dummy) == "table" and dummy.tag == "spike-lib",
        type(dummy) == "table" and dummy.tag or type(dummy))
end

-- ① 状态文件读写
local function probeState()
    local base = getWorkPath()
    check("getWorkPath 返回非空路径", type(base) == "string" and #base > 0, base)
    if type(base) ~= "string" or #base == 0 then return end

    local dir = base .. "/saoif_state"
    if not fileExist(dir) then mkdir(dir) end
    local path = dir .. "/state.json"

    local data = {
        fishing = { nextRun = os.time() + 3600, successCount = 3 },
        daily   = { nextRun = os.time() - 60, successCount = 1 },
        note    = "探针写入",
    }

    local okEnc, enc = pcall(jsonLib.encode, data)
    check("jsonLib.encode 可用", okEnc and type(enc) == "string", okEnc and enc or tostring(enc))
    if not okEnc then return end

    check("writeFile 写入状态文件", writeFile(path, enc) == true, path)
    check("fileExist 能看到文件", fileExist(path) == true)

    local raw = readFile(path)
    check("readFile 读回内容", type(raw) == "string" and #raw > 0, type(raw))

    local okDec, dec = pcall(jsonLib.decode, raw or "")
    check("jsonLib.decode 还原结构", okDec and type(dec) == "table" and dec.fishing ~= nil)
    if okDec and type(dec) == "table" and dec.fishing then
        check("还原后的字段值正确", dec.fishing.successCount == 3, tostring(dec.fishing.successCount))
    end
end

-- ⑤ 到期调度器原型（纯逻辑，不依赖设备）
local function probeScheduler()
    local now = 1000000
    local tasks = {
        { name = "钓鱼",     enable = true,  nextRun = now + 60 },
        { name = "每日任务", enable = true,  nextRun = now - 10 },
        { name = "公告板",   enable = false, nextRun = now - 999 },
    }
    local picked
    for _, t in ipairs(tasks) do
        if t.enable and t.nextRun <= now then
            if not picked or t.nextRun < picked.nextRun then picked = t end
        end
    end
    check("调度器挑出最早到期的启用任务",
        picked ~= nil and picked.name == "每日任务",
        picked and picked.name or "nil")
end

-- ② 配置文件持久化：连开两次参数页，第一次写入并保存关闭，第二次读回比对
--    4 个控件都是「默认值 ≠ 写入值」的判别式，能明确区分"回填成功"与"用了 XML 默认值"
local function probeConfigPersistence()
    local marker = "标记" .. tostring(tickCount())
    local readText, readNum, readChecked, readSel

    local function onFirst(handle, event)
        if event == "onload" then
            setUIText(handle, 0, "edProbe", marker)
            setUIText(handle, 0, "edNum", "88")
            setUICheck(handle, 0, "chkMark", false)
            setUISelect(handle, 0, "selMode", 2)
            logger.info("[探针]假设② 第 1 次打开：写入 edProbe=" .. marker
                .. " edNum=88 chkMark=false selMode=2，随后自动保存关闭")
            closeWindow(handle, true)
        end
    end
    showUI("spike_config.ui", 560, 720, onFirst)

    local function onSecond(handle, event)
        if event == "onload" then
            readText    = getUIText(handle, 0, "edProbe")
            readNum     = getUIText(handle, 0, "edNum")
            readChecked = getUIChecked(handle, 0, "chkMark")
            readSel     = getUISelected(handle, 0, "selMode")
            logger.info(string.format(
                "[探针]假设② 第 2 次打开读到：edProbe=%s edNum=%s chkMark=%s selMode=%s",
                tostring(readText), tostring(readNum),
                tostring(readChecked), tostring(readSel)))
            closeWindow(handle, true)
        end
    end
    showUI("spike_config.ui", 560, 720, onSecond)

    check("配置文件回填 输入框 (空 -> 标记)", readText == marker, tostring(readText))
    check("配置文件回填 数字框 (45 -> 88)", tostring(readNum) == "88", tostring(readNum))
    check("配置文件回填 多选框 (true -> false)", readChecked == false, tostring(readChecked))
    check("配置文件回填 下拉框 (0 -> 2)", readSel == 2, tostring(readSel))
end

local function reportText()
    local lines = {}
    for i, r in ipairs(results) do
        lines[#lines + 1] = string.format("%d. %s %s", i, r.ok and "√" or "×", r.name)
    end
    if #lines == 0 then return "（无结果）" end
    return table.concat(lines, "\n")
end

function _M.run()
    logger.info("================ 框架探针开始 ================")

    probeRequire()
    probeState()
    probeScheduler()
    probeConfigPersistence()

    -- ③ 窗口循环：主界面 -> 参数页 -> 回主界面（用 upvalue 传用户意图）
    local action
    local rounds = 0

    while true do
        rounds = rounds + 1
        if rounds > 6 then
            logger.warn("窗口循环超过 6 轮，强制结束")
            break
        end
        action = nil

        local function onMainEvent(handle, event, arg1, arg2)
            if event == "onload" then
                setUIText(handle, 0, "lblReport", reportText())
                setUIText(handle, 0, "lblSched",
                    "钓鱼：1 小时后到期\n每日任务：已到期\n公告板：已禁用")
            elseif event == "onclick" then
                if arg2 == "btnConfig" then
                    action = "config"
                    closeWindow(handle, true)
                end
            elseif event == "onclose" then
                if arg1 then
                    action = action or "run"
                    closeWindow(handle, true)
                else
                    action = "quit"
                    closeWindow(handle, false)
                end
            end
        end

        logger.info(string.format(">>> 打开主界面（第 %d 轮）", rounds))
        local ret = showUI("spike_main.ui", 560, 700, onMainEvent)
        logger.info(string.format("<<< 主界面关闭: action=%s  返回配置长度=%s",
            tostring(action), ret ~= nil and #tostring(ret) or "nil"))

        if action == "quit" then break end

        if action == "config" then
            local cfgAction
            local function onCfgEvent(handle, event, arg1)
                if event == "onclose" then
                    if arg1 then
                        cfgAction = "save"
                        closeWindow(handle, true)
                    else
                        cfgAction = "back"
                        closeWindow(handle, false)
                    end
                end
            end
            logger.info(">>> 打开参数页（人工体验）")
            showUI("spike_config.ui", 560, 720, onCfgEvent)
            logger.info(string.format("<<< 参数页关闭: action=%s —— 返回主界面", tostring(cfgAction)))

        elseif action == "run" then
            logger.info("[探针]假设③ 通过：窗口循环可用（主界面 -> 参数页 -> 主界面，共 %d 轮）", rounds)
            break
        end
    end

    logger.info("================ 探针汇总 ================")
    for i, r in ipairs(results) do
        logger.info(string.format("  %d. %s %s", i, r.ok and "通过" or "失败", r.name))
    end
    logger.info("=========================================")
end

return _M
