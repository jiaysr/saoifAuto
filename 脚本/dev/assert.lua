-- 脚本/dev/assert.lua
-- 极简断言收集器：不中断执行，跑完统一报告
local _M = {}

local results = {}

local function record(entry)
    results[#results + 1] = entry
end

function _M.ok(cond, name, detail)
    record({ ok = cond and true or false, name = name, detail = detail })
    return cond and true or false
end

function _M.eq(actual, expected, name)
    return _M.ok(actual == expected, name,
        string.format("期望 %s，实际 %s", tostring(expected), tostring(actual)))
end

function _M.skip(name, why)
    record({ skip = true, name = name, detail = why })
end

function _M.reset()
    results = {}
end

function _M.summary()
    local pass, fail, skip = 0, 0, 0
    for _, r in ipairs(results) do
        if r.skip then skip = skip + 1
        elseif r.ok then pass = pass + 1
        else fail = fail + 1 end
    end
    return pass, fail, skip
end

function _M.report(tag)
    tag = tag or "selfcheck"
    for _, r in ipairs(results) do
        local mark = r.skip and "跳过" or (r.ok and "通过" or "失败")
        local detail = r.detail and ("  <" .. tostring(r.detail) .. ">") or ""
        print(string.format("[%s] %s %s%s", tag, mark, r.name, detail))
    end
    local pass, fail, skip = _M.summary()
    print(string.format("[%s] ===== 结果: %d 通过 / %d 失败 / %d 跳过 =====",
        tag, pass, fail, skip))
    return fail == 0
end

return _M
