-- 脚本/tools/capture.lua
-- 临时调试用采集脚本：把小地图区域截图以 base64 输出到日志，供 PC 端解码分析
-- 用法：临时把 saoif.lcprojit 的 lua entry 指向本文件后运行

local X1, Y1, X2, Y2 = 1088, 0, 1280, 200

local function main()
    local path = getSdPath() .. "/minimap_cap.png"
    snapShot(path, X1, Y1, X2, Y2)
    local b64 = getFileBase64(path)
    if not b64 then
        print("CAP_ERR: getFileBase64 nil")
        return
    end
    print(string.format("CAP_SIZE %d %d %d %d %d", X1, Y1, X2, Y2, #b64))
    local step = 8000
    local i = 1
    while i <= #b64 do
        print("B64:" .. string.sub(b64, i, i + step - 1))
        i = i + step
    end
    print("CAP_END")
end

local ok, err = pcall(main)
if not ok then
    print("CAP_ERR: " .. tostring(err))
end
