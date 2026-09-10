# 每日任务

对应 README 规划中的「每日任务」功能。

新任务落地步骤（详见设计文档 §6）：
1. 在本目录建 `task.lua`（返回任务表，含 name/title/ui/run）
2. 建 `界面/tasks/daily.ui`，**必须**含调度控件 `chkEnable` / `edPriority` /
   `edSuccessInterval` / `edFailureInterval` 与只读 `lblNextRun`
3. 在 `脚本/tasks/index.lua` 加一行 `"tasks.daily.task"`
