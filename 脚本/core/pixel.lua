-- 脚本/core/pixel.lua
-- 像素/颜色工具
-- getScreenPixel 返回的 arr 颜色为 BBGGRR（十进制，BGR 序）；getPixelColor 返回值为 RRGGBB 序。
-- 比色串格式："x|y|BBGGRR-偏色,..."
-- 性能约定：每次 getScreenPixel 都是一次屏幕取像，代价远大于 Lua 运算，
--           因此同一区域的多个判定应尽量合并为一次取色。

local _M = {}

-- 解析比色串为点列表 { {x,y,r,g,b}, ... }（r,g,b 为真实 RGB）
function _M.parsePoints(colorStr)
    local pts = {}
    for part in tostring(colorStr):gmatch("[^,]+") do
        local x, y, color = part:match("^(%d+)|(%d+)|(%x%x%x%x%x%x)")
        if x then
            local b = tonumber(color:sub(1, 2), 16)
            local g = tonumber(color:sub(3, 4), 16)
            local r = tonumber(color:sub(5, 6), 16)
            pts[#pts + 1] = { x = tonumber(x), y = tonumber(y), r = r, g = g, b = b }
        end
    end
    return pts
end

-- 逐点判定：实际色与参考色逐通道容差比较
local function pointMatch(arr, w, x1, y1, p, tol)
    local c = arr[(p.y - y1) * w + (p.x - x1 + 1)]
    if not c then return false end
    local r, g, b = colorToRGB(c)
    return math.abs(r - p.r) <= tol and math.abs(g - p.g) <= tol and math.abs(b - p.b) <= tol
end

-- 多点比色匹配率：逐点逐通道容差比较（对应 Python _check_colors，tol=15）
-- 返回 匹配数, 总数；取点失败时按 0 匹配处理
function _M.matchRatio(colorStr, tol)
    tol = tol or 15
    local pts = _M.parsePoints(colorStr)
    local total = #pts
    if total == 0 then return 0, 0 end
    local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(pts) do
        if p.x < x1 then x1 = p.x end
        if p.y < y1 then y1 = p.y end
        if p.x > x2 then x2 = p.x end
        if p.y > y2 then y2 = p.y end
    end
    local w, h, arr = getScreenPixel(x1, y1, x2, y2)
    if not w or w <= 0 then return 0, total end
    local matched = 0
    for _, p in ipairs(pts) do
        if pointMatch(arr, w, x1, y1, p, tol) then
            matched = matched + 1
        end
    end
    return matched, total
end

-- 批量比色：同一屏幕区域的多个比色串合并为一次取色完成判定
-- colorStrs: { 名称 = 比色串, ... }（各串应位于相近区域，并集区域不宜过大）
-- 返回: { 名称 = 是否达标(匹配率 >= rate), ... }
function _M.matchStates(colorStrs, tol, rate)
    tol = tol or 15
    rate = rate or 0.6
    local names, groups = {}, {}
    local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
    for name, str in pairs(colorStrs) do
        local pts = _M.parsePoints(str)
        names[#names + 1] = name
        groups[#names] = pts
        for _, p in ipairs(pts) do
            if p.x < x1 then x1 = p.x end
            if p.y < y1 then y1 = p.y end
            if p.x > x2 then x2 = p.x end
            if p.y > y2 then y2 = p.y end
        end
    end
    local out = {}
    if #names == 0 or x1 == math.huge then return out end
    local w, _, arr = getScreenPixel(x1, y1, x2, y2)
    for i, name in ipairs(names) do
        local pts = groups[i]
        local matched = 0
        if w and w > 0 then
            for _, p in ipairs(pts) do
                if pointMatch(arr, w, x1, y1, p, tol) then
                    matched = matched + 1
                end
            end
        end
        out[name] = (#pts > 0 and matched >= #pts * rate)
    end
    return out
end

-- 单次取色完成扫描列的两项检测：完美区域（绿色）与浮标位置（奶油色）
-- 完美区域（对应 Python 绿色检测）：G>225 且 B<210 且 R<165 且 (G-B)>15 且 (G-R)>60
-- 返回 pStart, pEnd（完美区域上下界）, needle（浮标 y 坐标）；未找到为 nil
function _M.scanColumn(scanX, y1, y2)
    local w, h, arr = getScreenPixel(scanX - 1, y1, scanX + 1, y2)
    if not w or w <= 0 then return nil end
    local col = 2 -- 取 x = scanX 一列
    local pStart, pEnd, needle
    for row = 0, h - 1 do
        local r, g, b = colorToRGB(arr[row * w + col])
        if not needle and r == 255 and g == 254 and b == 180 then
            needle = y1 + row
        end
        if g > 225 and b < 210 and r < 165 and (g - b) > 15 and (g - r) > 60 then
            if not pStart then pStart = y1 + row end
            pEnd = y1 + row
        end
    end
    return pStart, pEnd, needle
end

-- 调试输出：打印每个点的参考色与实际色（实际色已修正为真实 RGB）
function _M.dumpPoints(colorStr, label)
    local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
    local pts = _M.parsePoints(colorStr)
    for _, p in ipairs(pts) do
        if p.x < x1 then x1 = p.x end
        if p.y < y1 then y1 = p.y end
        if p.x > x2 then x2 = p.x end
        if p.y > y2 then y2 = p.y end
    end
    local w, h, arr = getScreenPixel(x1, y1, x2, y2)
    if not w or w <= 0 then
        print(string.format("  %s 取像素失败", label))
        return
    end
    for _, p in ipairs(pts) do
        local r, g, b = colorToRGB(arr[(p.y - y1) * w + (p.x - x1 + 1)])
        print(string.format("  %s (%d,%d) 参考=(%3d,%3d,%3d) 实际=(%3d,%3d,%3d)",
            label, p.x, p.y, p.r, p.g, p.b, r, g, b))
    end
end

return _M
