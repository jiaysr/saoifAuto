-- 脚本/spike/probe3.lua
-- 验证 getUIConfig(name)：不开窗口能否读回 UI 配置文件，返回结构是什么样
--
-- 背景：若可用，每个任务的调度设置（启用/优先级/间隔）就能直接放在它自己的
-- 参数页里、靠 lrjl 自动持久化，调度器用这个函数读取，不必另存一份到 state.json。
--
-- 读的 spike_config.config 是前面探针写过的，已知内容：
--   edProbe=标记17  edNum=88  chkMark=false  selMode=2

local logger = require("core.logger")

local function dump(t, indent)
    indent = indent or "  "
    for k, v in pairs(t) do
        if type(v) == "table" then
            logger.info(indent .. tostring(k) .. " = {")
            dump(v, indent .. "  ")
            logger.info(indent .. "}")
        else
            logger.info(string.format("%s%s = %s  (%s)", indent, tostring(k), tostring(v), type(v)))
        end
    end
end

local function run()
    logger.info("========= getUIConfig 探针 =========")

    for _, name in ipairs({ "spike_config.config", "spike_overview.config", "saoif.config" }) do
        logger.info("--- 读取 " .. name .. " ---")
        local ok, arr = pcall(getUIConfig, name)
        if not ok then
            logger.error("调用失败: " .. tostring(arr))
        else
            logger.info("返回类型 = " .. type(arr))
            if type(arr) == "table" then
                dump(arr)
            else
                logger.info("返回值 = " .. tostring(arr))
            end
        end
    end

    logger.info("========= 探针结束 =========")
end

return { run = run }
