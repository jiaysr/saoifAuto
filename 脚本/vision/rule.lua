-- 脚本/vision/rule.lua
-- 规则对象：把「特征数据」声明成数据，把「怎么匹配/点击」收敛到这里。
-- 业务代码里不再出现裸露的比色串与坐标。
local pixel = require("vision.pixel")

local _M = {}

local DEFAULTS = {
    color = { tol = 15, rate = 0.6 },
    image = { sim = 0.8, delta = "101010" },
}

function _M.color(str, opt)
    opt = opt or {}
    return {
        kind = "color",
        str  = str,
        tol  = opt.tol  or DEFAULTS.color.tol,
        rate = opt.rate or DEFAULTS.color.rate,
    }
end

function _M.image(file, opt)
    opt = opt or {}
    return {
        kind  = "image",
        file  = file,
        roi   = opt.roi,
        sim   = opt.sim   or DEFAULTS.image.sim,
        delta = opt.delta or DEFAULTS.image.delta,
    }
end

function _M.click(x, y)
    return { kind = "click", x = x, y = y }
end

-- ===== 通用动作 =====

function _M.appear(r)
    if r.kind == "color" then
        local m, n = pixel.matchRatio(r.str, r.tol)
        return n > 0 and m >= n * r.rate
    elseif r.kind == "image" then
        if not r.roi then return false end
        -- findPic 返回 ret, x, y；ret 为图片索引，-1 表示未找到
        local ret, x, y = findPic(r.roi[1], r.roi[2], r.roi[3], r.roi[4], r.file, r.delta, 0, r.sim)
        return ret ~= -1 and x ~= -1 and y ~= -1
    end
    return false
end

function _M.waitAppear(r, timeoutMs)
    local deadline = tickCount() + (timeoutMs or 5000)
    repeat
        if _M.appear(r) then return true end
        sleep(30)
    until tickCount() >= deadline
    return false
end

function _M.clickRule(r)
    if r.kind == "click" then
        tap(r.x, r.y)
        return true
    elseif r.kind == "image" and r.roi then
        -- findPic 返回 ret, x, y；ret 为图片索引，-1 表示未找到
        local ret, x, y = findPic(r.roi[1], r.roi[2], r.roi[3], r.roi[4], r.file, r.delta, 0, r.sim)
        if ret ~= -1 and x ~= -1 and y ~= -1 then
            tap(x + math.floor((r.roi[3] - r.roi[1]) / 2), y + math.floor((r.roi[4] - r.roi[2]) / 2))
            return true
        end
    end
    return false
end

function _M.appearThenClick(r)
    if _M.appear(r) then
        return _M.clickRule(r)
    end
    return false
end

function _M.dumpPoints(str, label)
    pixel.dumpPoints(str, label)
end

return _M
