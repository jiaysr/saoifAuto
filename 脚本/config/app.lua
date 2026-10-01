-- 脚本/config/app.lua
-- 全局配置：运行与调试
return {
    id = "app",
    group = "全局",
    name = "运行与调试",
    desc = "配置保存、详细日志",
    order = 10,
    defaults = { saveConfig = true, verbose = false },
    schema = {
        { key = "saveConfig", label = "记住配置",   type = "bool", tip = "关闭后每次运行都用默认值" },
        { key = "verbose",    label = "详细日志",   type = "bool" },
    },
    apply = function(v)
        -- 供入口/任务读取的全局开关（不覆盖各模块自身参数）
        _G.SAOIF_CFG = {
            saveConfig = v.saveConfig ~= false,
            verbose = v.verbose == true,
        }
    end,
}
