-- 脚本/vision/image.lua
-- 找图封装：统一 findPic 的返回约定（-1 表示未找到）
local _M = {}

-- 返回 中心点 x, y；未找到返回 nil
function _M.findCenter(rule)
    if not rule.roi then return nil end
    -- findPic 返回 ret, x, y；ret 为图片索引，-1 表示未找到
    local ret, x, y = findPic(rule.roi[1], rule.roi[2], rule.roi[3], rule.roi[4],
        rule.file, rule.delta or "101010", 0, rule.sim or 0.8)
    if ret == -1 or x == -1 or y == -1 then return nil end
    return x + math.floor((rule.roi[3] - rule.roi[1]) / 2),
           y + math.floor((rule.roi[4] - rule.roi[2]) / 2)
end

return _M
