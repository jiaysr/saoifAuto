-- 脚本/tasks/minimap/vars.lua
-- 本任务的变量（纯数据表，勿写逻辑/require）；H5 界面用 sync-tasks.mjs 解析成表单
return {
    id    = "minimap",
    name  = "小地图调试",
    desc  = "小地图/大地图识别调试：视野朝向、角色朝向、图标标记，HUD 实时显示；可开启旋转自检。",
    order = 20,
    defaults = {
    func = "小地图调试", durationS = 30, intervalMs = 500,
    votes = 3, minConf = 0.85, minVotes = 2,
    facing = true, facingCalib = true, facingVotes = 1,
    selfTest = false, debugScan = false, mmShowHud = true,
},
    schema   = {
    { key = "durationS",   label = "运行时长(秒)",  type = "int",    min = 5,  max = 600, step = 5 },
    { key = "intervalMs",  label = "刷新间隔(ms)",  type = "int",    min = 100, max = 3000, step = 50 },
    { key = "votes",       label = "视野投票帧数",  type = "int",    min = 1, max = 7 },
    { key = "minConf",     label = "conf 门限",     type = "number", min = 0, max = 1, step = 0.05 },
    { key = "minVotes",    label = "最少一致票",    type = "int",    min = 1, max = 5 },
    { key = "facing",      label = "显示角色朝向",  type = "bool" },
    { key = "facingCalib", label = "套用朝向标定",  type = "bool" },
    { key = "facingVotes", label = "角色投票帧数",  type = "int",    min = 1, max = 5 },
    { key = "selfTest",    label = "转向自检",      type = "bool" },
    { key = "debugScan",   label = "打印扫描图",    type = "bool" },
    { key = "mmShowHud",   label = "显示 HUD",      type = "bool" },
},
}
