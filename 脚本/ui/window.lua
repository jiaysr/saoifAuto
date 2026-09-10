-- 脚本/ui/window.lua
-- showUI 的薄封装，统一「关一个再开一个」的窗口流转惯例。
--
-- 实测约束（不要绕开）：
--   * showUI 阻塞，窗口关闭才返回，返回值为配置 JSON 字符串
--   * 禁止在 onload 里 closeWindow —— 逻辑上会返回，但窗口不会真的关掉，会叠窗
--   * 意图用闭包 upvalue 回传：回调里记下 action，showUI 返回后主流程读取
local _M = {}

_M.CLOSE_SAVE   = true
_M.CLOSE_CANCEL = false

-- onEvent(handle, event, arg1, arg2, arg3) 为用户回调；返回值为配置 JSON
function _M.show(uifile, w, h, onEvent)
    return showUI(uifile, w, h, onEvent)
end

-- 关闭窗口。save 为 true 时 lrjl 会持久化控件值到该窗口绑定的配置文件
-- 注意：必须把 save 强制成真正的布尔再传给 closeWindow。
-- 实测 lrjl 回调里的 arg1 未必是 boolean（可能是 1 之类的真值），
-- 而 `1 == true` 为 false —— 那样窗口会以 save=false 关闭，
-- 任务参数页的所有修改会被静默丢弃，日志里完全看不出来。
function _M.close(handle, save)
    closeWindow(handle, not not save)
end

return _M
