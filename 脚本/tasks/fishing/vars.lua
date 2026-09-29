-- 脚本/tasks/fishing/vars.lua
-- 本任务的变量（纯数据表，勿写逻辑/require）；H5 界面用 sync-tasks.mjs 解析成表单
return {
    id    = "fishing",
    name  = "钓鱼",
    desc  = "自动钓鱼：识别钓场状态栏（开始/提竿/命中），自动追踪完美区域并提竿，循环钓鱼并统计次数。",
    order = 10,
    defaults = {
    func        = "钓鱼",
    loopTime    = 45,
    maxCatch    = 0,
    clickX      = 1173,
    clickY      = 510,
    scanX       = 1015,
    zoneY1      = 123,
    zoneY2      = 524,
    showHud     = true,
    debugColors = false,
    debugTrace  = false,
},
    schema   = {
    { key = "loopTime",    label = "单轮时长(秒)", type = "int", min = 5,  max = 600,  step = 5 },
    { key = "maxCatch",    label = "目标条数",     type = "int", min = 0,  max = 999,  tip = "0 = 不限" },
    { key = "clickX",      label = "提竿 X",       type = "int", min = 0,  max = 1280 },
    { key = "clickY",      label = "提竿 Y",       type = "int", min = 0,  max = 720 },
    { key = "scanX",       label = "扫描列 X",     type = "int", min = 0,  max = 1280, tip = "浮标比色所在竖列" },
    { key = "zoneY1",      label = "判定区上 Y",   type = "int", min = 0,  max = 720 },
    { key = "zoneY2",      label = "判定区下 Y",   type = "int", min = 0,  max = 720 },
    { key = "showHud",     label = "显示 HUD",     type = "bool" },
    { key = "debugColors", label = "比色调试",     type = "bool" },
    { key = "debugTrace",  label = "调试日志",     type = "bool" },
},
}
