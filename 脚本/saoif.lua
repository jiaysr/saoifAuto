-- 脚本/saoif.lua
-- 主入口：自动发现 任务(tasks/*)/配置(config/*) → H5 界面收集配置 → 分发到任务
-- 约定：
--   tasks/<id>/vars.lua   纯数据(id/name/desc/order/defaults/schema)，界面据此渲染表单
--   tasks/<id>/main.lua   逻辑(name/desc/schema/defaults 从 vars 取) + readConfig/run
--   config/<name>.lua     全局配置(同结构 + 可选 apply(v) 启动时灌回模块)
-- 发现：① lfs.dir 列脚本根目录 ② 失败则退回 tasks/index.lua 清单
-- 脚本根：从 package.path 里解析 ".../脚本/?.lua"（getWorkPath() 不是脚本目录）

local logger = require("core.logger")
local dispatcher = require("core.dispatcher")
local bridge = require("ui.h5_bridge")

-- ---------- 脚本根 ----------
local function scriptRoot()
    for seg in tostring(package.path):gmatch("[^;]+") do
        local pre = seg:match("^(.-)%?%.lua$")
        if pre and pre:find("脚本", 1, true) then return pre end
    end
    return nil
end
local ROOT = scriptRoot()
logger.info("脚本根: " .. tostring(ROOT))

local lfs = require("lfs")
local function listDirs(path)
    local out, ok = {}, pcall(function()
        for f in lfs.dir(path) do
            if f ~= "." and f ~= ".." and lfs.attributes(path .. "/" .. f, "mode") == "directory" then
                out[#out + 1] = f
            end
        end
    end)
    return ok and out or nil
end
local function listLua(path)
    local out, ok = {}, pcall(function()
        for f in lfs.dir(path) do
            if f:sub(-4) == ".lua" then out[#out + 1] = f:sub(1, -5) end
        end
    end)
    if ok then table.sort(out) end
    return ok and out or nil
end

-- ---------- 注册任务 ----------
local function loadTasks()
    local ids = ROOT and listDirs(ROOT .. "tasks") or nil
    if not ids or #ids == 0 then
        local okM, list = pcall(require, "tasks.index")
        ids = (okM and type(list) == "table") and list or {}
        logger.warn("目录发现不可用，改用 tasks/index.lua 清单（" .. #ids .. " 个）")
    end
    local n = 0
    for _, id in ipairs(ids) do
        local ok, err = pcall(require, "tasks." .. id .. ".main")
        if ok then n = n + 1 else logger.error("任务加载失败 " .. id .. ": " .. tostring(err)) end
    end
    return n
end

-- ---------- 全局配置 ----------
local configs = {}
local function loadConfigs()
    local names = ROOT and listLua(ROOT .. "config") or nil
    if not names then names = { "app", "control", "vision" } end
    for _, name in ipairs(names) do
        local ok, c = pcall(require, "config." .. name)
        if ok and type(c) == "table" then
            configs[#configs + 1] = c
        else
            logger.warn("配置加载失败 " .. name .. ": " .. tostring(c))
        end
    end
    table.sort(configs, function(a, b) return (a.order or 100) < (b.order or 100) end)
    return #configs
end

local taskN = loadTasks()
local cfgN = loadConfigs()
logger.info(string.format("已注册 %d 个任务 / %d 组全局配置", taskN, cfgN))

-- ---------- 初值：任务+配置的 defaults ← 上次保存 ----------
local function mergeDefaults(dst, list)
    for _, t in ipairs(list) do
        if type(t.defaults) == "table" then
            for k, v in pairs(t.defaults) do dst[k] = v end
        end
    end
    return dst
end
local values = {}
mergeDefaults(values, dispatcher.all())
mergeDefaults(values, configs)
local saved = bridge.loadSaved()
if saved then
    for k, v in pairs(saved) do values[k] = v end
    logger.info("已载入上次保存的配置")
end

-- 用(保存的/默认的)配置值灌回各模块，保证本次运行按用户设置走
for _, c in ipairs(configs) do
    if type(c.apply) == "function" then
        local v = {}
        for k, dv in pairs(c.defaults or {}) do
            v[k] = (values[k] ~= nil) and values[k] or dv
        end
        local ok, err = pcall(c.apply, v)
        if not ok then logger.warn("配置应用失败 " .. tostring(c.id) .. ": " .. tostring(err)) end
    end
end

-- ---------- 下发给 H5 ----------
local function collectTaskList()
    local list = {}
    for _, t in ipairs(dispatcher.all()) do
        list[#list + 1] = {
            id = t.id or t.name,
            name = t.name,
            desc = t.desc or ("运行功能：" .. t.name),
            schema = t.schema,
        }
    end
    return list
end
local function collectConfigList()
    local list = {}
    for _, c in ipairs(configs) do
        list[#list + 1] = {
            id = c.id, group = c.group or "全局", name = c.name,
            desc = c.desc or "", schema = c.schema,
        }
    end
    return list
end
-- 按 id 或 name 找任务（H5 提交的是 id）
local function findTask(key)
    key = tostring(key or "")
    for _, t in ipairs(dispatcher.all()) do
        if (t.id or t.name) == key or t.name == key then return t end
    end
    return nil
end

logger.info("SAOIF 自动助手启动（H5 界面）")

local AUTOTEST_FLAG = tostring(getSdPath()) .. "/saoif_h5_autotest"
local autoTest = fileExist(AUTOTEST_FLAG)
if autoTest then
    logger.info("[自检] 检测到自检标记，本次仅验证 H5 变量连通")
    delfile(AUTOTEST_FLAG)
end

local cfg = bridge.open({
    ver = "0.2.0-h5",
    tasks = collectTaskList(),
    configs = collectConfigList(),
    values = values,
    autoTest = autoTest,
    validate = function(c)
        local key = tostring(c.func or "")
        if key == "" then return false, "请先选择一个功能再运行！" end
        if not findTask(key) then return false, "未找到功能模块: " .. key end
        return true
    end,
})

if not cfg then
    logger.info("未提交配置（退出或关闭界面），脚本结束")
    return
end

local task = findTask(cfg.func)
local ok, taskCfg = pcall(task.readConfig, cfg)
if not ok or not taskCfg then
    logger.error("读取配置失败: " .. tostring(taskCfg))
    toast("读取配置失败，请检查设置项")
    return
end

-- app 配置里的「记住配置」开关
if not (_G.SAOIF_CFG and _G.SAOIF_CFG.saveConfig == false) then
    bridge.save(cfg)
else
    logger.info("已按设置跳过保存配置")
end

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
