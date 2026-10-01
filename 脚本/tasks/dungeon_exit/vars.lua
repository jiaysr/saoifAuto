-- 脚本/tasks/dungeon_exit/vars.lua
-- 本任务的变量（纯数据表，勿写逻辑/require）；H5 界面用 sync-tasks.mjs 解析成表单
return {
    id    = "dungeon_exit",
    name  = "副本出口",
    desc  = "副本出口自动寻路：识别出口图标 → 靠近 → 攻击键变放大镜后点击 → 弹窗确认离开。",
    order = 30,
    defaults = {
    func = "副本出口", mode = "auto", maxMs = 120000,
},
    schema   = {
    { key = "mode",  label = "寻路模式", type = "enum",
      options = { "auto", "mini", "bigmap" },
      tip = "auto=小地图看不到出口时自动开大地图" },
    { key = "maxMs", label = "超时(ms)", type = "int", min = 10000, max = 600000, step = 5000 },
},
}
