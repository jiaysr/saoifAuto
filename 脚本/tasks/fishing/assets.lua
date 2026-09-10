-- 脚本/tasks/fishing/assets.lua
-- 钓鱼功能的特征与坐标常量。数据与逻辑分离：这里只有数据，匹配行为在 vision/rule.lua。
-- 坐标基准：横屏 1280x720（设备 720x1280 竖屏 + rotate=1）
local rule = require("vision.rule")

-- 比色串格式："x|y|BBGGRR-偏色,..."（颜色为原 Python RRGGBB 转 BBGGRR）
local DO1 = "1182|485|00CFCF-0F0F0F,1180|496|00DDDE-0F0F0F,1179|508|3675B5-0F0F0F,"
    .. "1179|517|07F3F3-0F0F0F,1178|530|02FFFF-0F0F0F,1177|547|26487B-0F0F0F,"
    .. "1157|546|4AF7F7-0F0F0F,1155|549|57F0F0-0F0F0F,1205|548|A6B7C8-0F0F0F"

local DO2 = "1187|494|7D5C25-0F0F0F,1174|502|304459-0F0F0F,1161|508|7C5C24-0F0F0F,"
    .. "1163|520|7D6527-0F0F0F,1162|530|565C5D-0F0F0F,1163|539|786437-0F0F0F,"
    .. "1183|538|7D6A29-0F0F0F,1195|536|776F4C-0F0F0F,1206|527|112A4C-0F0F0F,"
    .. "1211|512|79511B-0F0F0F"

local DO3 = "1183|494|006D6D-0F0F0F,1182|509|162F50-0F0F0F,1181|520|017979-0F0F0F,"
    .. "1177|536|017F7F-0F0F0F,1157|535|027676-0F0F0F,1176|547|3D4A5F-0F0F0F,"
    .. "1181|553|162741-0F0F0F,1186|548|1E2F49-0F0F0F,1199|542|172B4C-0F0F0F"

local DO4 = "1186|494|F8B446-0F0F0F,1168|515|FBD451-0F0F0F,1165|526|FBCE50-0F0F0F,"
    .. "1165|538|E0E0D7-0F0F0F,1178|538|FAD357-0F0F0F,1199|536|3265BA-0F0F0F,"
    .. "1202|534|DDDDDD-0F0F0F,1202|519|EBDCB1-0F0F0F,1193|501|FBC84E-0F0F0F"

local TARGET = "499|108|F7F9FB-0F0F0F,499|109|F7F9FB-0F0F0F,499|113|F7F9FB-0F0F0F,"
    .. "499|116|F7F9FB-0F0F0F,499|118|F7F9FB-0F0F0F,499|119|F7F9FB-0F0F0F,"
    .. "503|119|F7F7F9-0F0F0F,505|118|DD3434-0F0F0F,500|109|E15C5C-0F0F0F"

-- 逐通道容差 15，点匹配率 0.6（对应原 Python tol=15 / m >= n*0.6）
local COLOR_OPT = { tol = 15, rate = 0.6 }

return {
    DO1    = rule.color(DO1, COLOR_OPT),
    DO2    = rule.color(DO2, COLOR_OPT),
    DO3    = rule.color(DO3, COLOR_OPT),
    DO4    = rule.color(DO4, COLOR_OPT),
    TARGET = rule.color(TARGET, COLOR_OPT),

    -- 结算弹窗右上角 X 按钮模板（打包在 资源/saoif.rc，findPic 用裸文件名引用）
    -- 对应原 Python I_CLONE: roi=(915,173,961,217), threshold=0.8
    CLONE  = rule.image("Fishing_clone.png", {
        roi = { 915, 173, 961, 217 },   -- 搜索区域 46x44
        halfW = 20, halfH = 15,         -- 模板 40x31 的一半（原 Python CLONE_HALF_W/H）
        sim = 0.8,
    }),
}

-- 开始 / 提竿按钮不在这里：它的坐标是用户可配的，唯一来源是 config.defaults()
-- 里的 clickX / clickY（避免与参数页出现两份会漂移的默认值）。
