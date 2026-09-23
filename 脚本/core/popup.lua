-- 脚本/core/popup.lua
-- 公共弹窗处理模块
-- 当前负责：每日登录奖励弹窗（约每天 3:00 出现）
--   流程：【图2】Login Bonus 主弹窗（标题比色）→ 点"一鍵領取" →【图1】Login Bonus Get 弹窗（区域找图 OK）→ 点 OK 关闭
-- 序列确定，串联处理：一次调用内走完整流程再返回，避免中间态被任务的状态判定采样到。
-- 任务循环中轮询调用 M.checkLoginBonus() 即可，内部有冷却保护。

local logger = require("core.logger")

local M = {}

-- ==================== 配置区（坐标/特征/图片自行采集填写） ====================
M.CFG = {
  -- 【图2】顶部 "Login Bonus" 标题比色特征
  -- 格式："x|y|RRGGBB,x|y|RRGGBB,..."（颜色与 getPixelColor 一致，RRGGBB 序）
  titleBonus = "595|29|757575,595|30|757575,595|31|757575,595|41|757575,609|42|757575,614|42|757575,619|42|757575,623|42|757575,626|42|757575",
  titleSim = 0.9,         -- cmpColorEx 相似度(0-1)，所有点都需匹配

  -- 【图2】"一鍵領取" 按钮点击坐标（横屏 1280x720）
  claimX = 962,
  claimY = 666,

  -- 【图1】底部 OK 按钮模板（图片放 资源/ 目录，findPic 用裸文件名引用）
  okImg = "剪裁0.png",
  okRoi = {357,321,740,704 }, -- 搜索区域 x1,y1,x2,y2；全屏填 0,0,0,0
  okDelta = "101010",     -- 找图偏色
  okSim = 0.8,            -- 相似度
  okTapDx = 0,            -- 点击点相对模板左上角偏移（一般填 模板宽/2, 模板高/2）
  okTapDy = 0,

  -- 时序参数
  waitOkMs = 3000,        -- 点完一键领取后，等待【图1】出现的超时(ms)
  okSettleMs = 300,       -- 找到 OK 后等动画稳定的时间(ms)，随后重新定位再点击
  afterMs = 600,          -- 点完 OK 后等界面回到游戏的时间(ms)
  cooldownMs = 5000,      -- 处理完成后的冷却(ms)，避免同一弹窗反复触发
}

-- 比色匹配（直接使用 cmpColorEx：1 完全匹配，0 未匹配）
local function isMatch(colorStr)
  if colorStr == "" then return false end
  return cmpColorEx(colorStr, M.CFG.titleSim) == 1
end

-- 查找【图1】OK 按钮原始坐标（未找到返回 nil）
local function findOk()
  if M.CFG.okImg == "" then return nil end
  local r, cx, cy = findPic(M.CFG.okRoi[1], M.CFG.okRoi[2], M.CFG.okRoi[3], M.CFG.okRoi[4],
  M.CFG.okImg, M.CFG.okDelta, 0, M.CFG.okSim)
  if r ~= -1 and cx ~= -1 then
    return cx, cy
  end
  return nil
end

-- 等待【图1】出现并返回稳定后的点击坐标
-- timeoutMs 为 0 时只查一次（用于已在图1状态的兜底）
local function waitOk(timeoutMs)
  local deadline = tickCount() + timeoutMs
  repeat
    local cx, cy = findOk()
    if cx then
      sleep(M.CFG.okSettleMs)          -- 等弹出动画结束
      local x2, y2 = findOk()          -- 重新定位，避免点到动画中间位置
      return x2 or cx, y2 or cy
    end
    sleep(80)
  until tickCount() >= deadline
  return nil
end

local lastHandled = 0

-- 检测并处理登录奖励弹窗（任务循环中轮询调用）
-- 返回 "claim" 已完成【图2】一键领取并关闭【图1】
-- 返回 "ok"    仅关闭了【图1】领取结果弹窗（兜底，如脚本启动时已在图1）
-- 返回 nil     无弹窗 / 配置未填写 / 冷却中
function M.checkLoginBonus()
  if M.CFG.titleBonus == "" and M.CFG.okImg == "" then return nil end
  if tickCount() - lastHandled < M.CFG.cooldownMs then return nil end

  -- 【图2】状态：点一键领取 → 必然弹出【图1】→ 点 OK 关闭
  if isMatch(M.CFG.titleBonus) then
    logger.info("登录奖励：点击一键领取")
    tap(M.CFG.claimX, M.CFG.claimY)
    local x, y = waitOk(M.CFG.waitOkMs)
    if x then
      logger.info("登录奖励：点击 OK 关闭领取弹窗")
      tap(x + M.CFG.okTapDx, y + M.CFG.okTapDy)
      lastHandled = tickCount()
      sleep(M.CFG.afterMs)
      return "claim"
    end
    logger.warn("登录奖励：点击一键领取后未等到 OK 弹窗")
    lastHandled = tickCount()
    return "claim"
  end

  -- 【图1】兜底：直接处于领取结果弹窗
  local x, y = waitOk(0)
  if x then
    logger.info("登录奖励：点击 OK 关闭领取弹窗")
    tap(x + M.CFG.okTapDx, y + M.CFG.okTapDy)
    lastHandled = tickCount()
    sleep(M.CFG.afterMs)
    return "ok"
  end

  return nil
end

return M
