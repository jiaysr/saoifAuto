-- 脚本/core/pixel.lua
-- 像素/颜色工具
-- 引擎颜色格式为 "BBGGRR"，比色串解析与竖列像素扫描工具。

local _M = {}

-- 调试输出：解析 cmpColorEx 比色串，打印每个点的参考色与实际色
-- 比色串格式："x|y|BBGGRR-偏色,..."
function _M.dumpPoints(colorStr, label)
    for part in tostring(colorStr):gmatch("[^,]+") do
        local x, y, color = part:match("^(%d+)|(%d+)|(%x+)")
        if x then
            color = color:match("^(%x%x%x%x%x%x)") or color -- 去掉偏色后缀
            local c = getPixelColor(tonumber(x), tonumber(y))
            local r, g, b = colorToRGB(c)
            local rr, gg, bb = colorToRGB(color)
            print(string.format("  %s (%s,%s) 参考=(%3d,%3d,%3d) 实际=(%3d,%3d,%3d)",
                label, x, y, rr, gg, bb, r, g, b))
        end
    end
end

-- 解析引擎颜色值(可为字符串或数字) -> r, g, b
function _M.parseColor(c)
    if type(c) == "number" then
        return colorToRGB(c)
    end
    local s = tostring(c):match("(%x%x%x%x%x%x)%s*$")
    if not s then
        return colorToRGB(c)
    end
    -- 字符串为 "BBGGRR"
    local b = tonumber(s:sub(1, 2), 16)
    local g = tonumber(s:sub(3, 4), 16)
    local r = tonumber(s:sub(5, 6), 16)
    return r, g, b
end

-- 在竖直扫描列上寻找完美区域（对应 Python 版 crop[123:523, 1014:1016] 的绿色检测）
-- 返回 p_start, p_end（未找到返回 nil）
-- 完美区判定: g>225 且 r<210 且 b<165 且 (g-r)>15 且 (g-b)>60
function _M.findPerfectZone(scanX, y1, y2)
    local w, h, arr = getScreenPixel(scanX - 1, y1, scanX + 1, y2)
    if not w or w < 0 then return nil end
    local col = 2 -- 取中间列 (x = scanX)
    local pStart, pEnd
    for row = 0, h - 1 do
        local r, g, b = _M.parseColor(arr[row * w + col])
        if g and g > 225 and r < 210 and b < 165 and (g - r) > 15 and (g - b) > 60 then
            if not pStart then pStart = y1 + row end
            pEnd = y1 + row
        end
    end
    if pStart then return pStart, pEnd end
    return nil
end

-- 在竖直扫描列上寻找浮标位置（颜色精确匹配 RGB(255,254,180)）
-- 返回浮标 y 坐标（未找到返回 nil）
function _M.findNeedle(scanX, y1, y2)
    local w, h, arr = getScreenPixel(scanX - 1, y1, scanX + 1, y2)
    if not w or w < 0 then return nil end
    local col = 2
    for row = 0, h - 1 do
        local r, g, b = _M.parseColor(arr[row * w + col])
        if r == 255 and g == 254 and b == 180 then
            return y1 + row
        end
    end
    return nil
end

return _M
