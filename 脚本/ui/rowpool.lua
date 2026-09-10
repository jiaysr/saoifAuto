-- 脚本/ui/rowpool.lua
-- 固定行池：静态 XML 无法运行时增删控件，故预放 N 个行按钮，
-- 运行时填文字、把多余行隐藏（setUIVisible 8 = 隐藏且不占位）。
-- 点击时用 indexOf 从控件 id 反查行号，再 taskAt 反查任务。
local _M = {}

-- 从控件 id 里解析行号： "btnRow3" -> 3；不匹配返回 nil
function _M.indexOf(id, prefix)
    prefix = prefix or "btnRow"
    if type(id) ~= "string" then return nil end
    local n = string.match(id, "^" .. prefix .. "(%d+)$")
    if not n then return nil end
    return tonumber(n)
end

-- 通用解析：给多个前缀，返回 行号, 前缀
function _M.matchAny(id, prefixes)
    for _, prefix in ipairs(prefixes) do
        local i = _M.indexOf(id, prefix)
        if i then return i, prefix end
    end
    return nil
end

function _M.new(prefix, rows)
    return { prefix = prefix, rows = rows, map = {} }
end

-- 填充：list 的第 i+1 项填到第 i 行；超出 list 的行清空并隐藏
-- fmt(item) 返回该行显示文字
function _M.fill(pool, handle, page, list, fmt)
    for i = 0, pool.rows - 1 do
        local id = pool.prefix .. tostring(i)
        local item = list[i + 1]
        if item then
            pool.map[i] = item
            setUIText(handle, page, id, fmt(item))
            setUIVisible(handle, page, id, 0)
        else
            pool.map[i] = nil
            setUIText(handle, page, id, "")
            setUIVisible(handle, page, id, 8)
        end
    end
end

function _M.taskAt(pool, i)
    return pool.map[i]
end

function _M.visibleCount(pool)
    local n = 0
    for _ in pairs(pool.map) do n = n + 1 end
    return n
end

return _M
