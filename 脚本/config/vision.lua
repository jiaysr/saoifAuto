-- 脚本/config/vision.lua
-- 全局配置：视觉阈值（视野锥 / 角色朝向 / 出口模板）
return {
    id = "vision",
    group = "全局",
    name = "视觉阈值",
    desc = "视野锥颜色与半径、投票门限、模板相似度",
    order = 30,
    defaults = {
        lumMin = 145, satMax = 85, rMax = 50,
        confMin = 0.85, voteFrames = 3, voteTol = 12, minVotes = 2,
        facingSimMin = 0.65, exitSim = 0.68, bigExitSim = 0.52,
    },
    schema = {
        { key = "lumMin",      label = "锥体最低亮度", type = "int",    min = 80,  max = 220 },
        { key = "satMax",      label = "饱和度上限",   type = "int",    min = 20,  max = 160, tip = "排除绿色NPC点/黄色图标" },
        { key = "rMax",        label = "锥体搜索半径", type = "int",    min = 20,  max = 90 },
        { key = "confMin",     label = "conf 门限",    type = "number", min = 0,   max = 1, step = 0.05 },
        { key = "voteFrames",  label = "投票帧数",     type = "int",    min = 1,   max = 7 },
        { key = "voteTol",     label = "角度容差(°)",  type = "number", min = 3,   max = 40 },
        { key = "minVotes",    label = "最少一致票",   type = "int",    min = 1,   max = 5 },
        { key = "facingSimMin",label = "角色朝向门限", type = "number", min = 0.3, max = 0.95, step = 0.05 },
        { key = "exitSim",     label = "小图出口门限", type = "number", min = 0.3, max = 0.95, step = 0.02 },
        { key = "bigExitSim",  label = "大图出口门限", type = "number", min = 0.3, max = 0.95, step = 0.02 },
    },
    apply = function(v)
        local vc = require("core.viewcone")
        vc.CFG.lumMin = v.lumMin
        vc.CFG.satMax = v.satMax
        vc.CFG.rMax = v.rMax
        vc.VOTE.minConf = v.confMin
        vc.VOTE.frames = v.voteFrames
        vc.VOTE.tol = v.voteTol
        vc.VOTE.minVotes = v.minVotes
        local fc = require("core.facing")
        fc.SIM_MIN = v.facingSimMin
        local ex = require("core.exit")
        ex.CFG.exitSim = v.exitSim
        ex.CFG.bigExitSim = v.bigExitSim
    end,
}
