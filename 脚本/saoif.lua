-- 脚本/saoif.lua
-- 主入口：H5(WebView) 界面收集配置 → 校验功能选择 → 分发到对应任务模块
-- 界面实现：脚本/ui/h5_page.lua（由 界面/saoif_h5.html 生成），变量经 Base64(JSON) 通道与 Lua 实时互通
-- 注意：H5 功能列表与默认参数来自各任务模块的 name / desc / defaults 字段

local logger = require("core.logger")
local dispatcher = require("core.dispatcher")
local bridge = require("ui.h5_bridge")

-- 加载并注册所有功能模块（新增功能在此追加一行即可）
require("tasks.fishing")

-- 汇总各任务的默认参数，作为 H5 初值（页面不写死业务默认值）
local function collectDefaults()
    local d = {}
    for _, t in ipairs(dispatcher.all()) do
        if type(t.defaults) == "table" then
            for k, v in pairs(t.defaults) do d[k] = v end
        end
    end
    return d
end

-- 功能列表（名称 + 说明）下发到 H5
local function collectTaskList()
    local list = {}
    for _, t in ipairs(dispatcher.all()) do
        list[#list + 1] = { name = t.name, desc = t.desc or ("运行功能：" .. t.name) }
    end
    return list
end

logger.info("SAOIF 自动助手启动（H5 界面）")

-- 自检模式：标记文件存在时，界面就绪后自动模拟一次"改参数 → 保存并运行"，
-- 仅验证 Lua ↔ H5 变量连通，不执行真实任务；验证后自动删除标记
local AUTOTEST_FLAG = tostring(getSdPath()) .. "/saoif_h5_autotest"
local autoTest = fileExist(AUTOTEST_FLAG)
if autoTest then
    logger.info("[自检] 检测到自检标记，本次仅验证 H5 变量连通")
    delfile(AUTOTEST_FLAG)
end

-- 初值 = 默认值 ← 上次保存的配置（sdcard/saoif_h5_config.json）
local values = collectDefaults()
local saved = bridge.loadSaved()
if saved then
    for k, v in pairs(saved) do values[k] = v end
    logger.info("已载入上次保存的配置")
end

-- 显示 H5 界面并等待用户提交；validate 在 Lua 侧做权威校验
local cfg = bridge.open({
    ver = "0.1.0-h5",
    tasks = collectTaskList(),
    values = values,
    autoTest = autoTest,
    validate = function(c)
        local name = tostring(c.func or "")
        if name == "" then
            return false, "请先选择一个功能再运行！"
        end
        if not dispatcher.find(name) then
            return false, "未找到功能模块: " .. name
        end
        return true
    end,
})

if not cfg then
    logger.info("未提交配置（退出或关闭界面），脚本结束")
    return
end

local task = dispatcher.find(cfg.func)
local ok, taskCfg = pcall(task.readConfig, cfg)
if not ok or not taskCfg then
    logger.error("读取配置失败: " .. tostring(taskCfg))
    toast("读取配置失败，请检查设置项")
    return
end

bridge.save(cfg)

if autoTest then
    logger.info("[自检] H5 变量连通自检通过，Lua 侧最终配置：")
    logger.info("[自检] " .. tostring(jsonLib.encode(taskCfg)))
    logger.info("[自检] 已跳过任务执行（自检模式）")
    return
end

logger.info("========== 开始运行功能: " .. task.name .. " ==========")

local okRun, err = xpcall(function()
    task.run(taskCfg)
end, function(e)
    return debug.traceback(e)
end)

if not okRun then
    logger.error("任务执行出错: " .. tostring(err))
    toast("任务执行出错，详见日志")
else
    logger.info("========== 功能执行完毕 ==========")
end
