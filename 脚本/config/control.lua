-- 脚本/config/control.lua
-- 全局配置：移动与转向（H5「设置」分区自动渲染；schema 驱动，新增参数只改这里）
return {
    id = "control",
    group = "全局",
    name = "移动与转向",
    desc = "摇杆中心/半径、推杆偏置、转向灵敏度",
    order = 20,
    defaults = {
        centerX = 164, centerY = 574, radius = 88,
        pushBiasDeg = 0, worldRelative = false, pxPerDeg = 2.5,
    },
    schema = {
        { key = "centerX",      label = "摇杆中心 X",  type = "int",    min = 0, max = 1280 },
        { key = "centerY",      label = "摇杆中心 Y",  type = "int",    min = 0, max = 720 },
        { key = "radius",       label = "推杆半径",    type = "int",    min = 20, max = 150 },
        { key = "pushBiasDeg",  label = "上推偏置(°)", type = "number", min = -90, max = 90 },
        { key = "worldRelative",label = "摇杆按世界方向", type = "bool" },
        { key = "pxPerDeg",     label = "拖拽 px/度",  type = "number", min = 1, max = 6, step = 0.1,
          tip = "镜头转向灵敏度（实测 2.2~2.7）" },
    },
    apply = function(v)
        local mv = require("core.move")
        mv.CFG.centerX = v.centerX
        mv.CFG.centerY = v.centerY
        mv.CFG.radius = v.radius
        mv.CFG.pushBiasDeg = v.pushBiasDeg
        mv.CFG.worldRelative = v.worldRelative and true or false
        local ex = require("core.exit")
        ex.CFG.pxPerDeg = v.pxPerDeg
    end,
}
