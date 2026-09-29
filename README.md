# SAOIF 自动化脚本（刀剑神域：关键斗士）

基于懒人精灵 IDE 开发的《刀剑神域：关键斗士》（Sword Art Online: Integral Factor）自动化脚本，为 7x24 运行的场景而设计，减少重复枯燥的日常操作。

- 适配服务器：国际服（繁体中文）
- 运行环境：安卓模拟器、云手机（真机后续可能适配）
- 脚本引擎：懒人精灵（Lua）

## 功能 Features

> 以下功能均为规划中，将随开发进度逐步实现。

- **公告板**：自动接取并完成公告板任务，循环刷取经验与道具。
- **活动**：自动进入活动副本，完成活动任务与兑换。
- **每日任务**：自动完成每日任务清单。
- **钓鱼**：自动钓鱼，自动收杆与抛竿。

## 安装使用

1. 在电脑或安卓设备上安装懒人精灵 IDE。
2. 将本项目导入懒人精灵，或通过项目目录加载。
3. 启动模拟器或云手机，安装《刀剑神域：关键斗士》国际服（繁中）客户端。
4. 在懒人精灵中连接设备。
5. 打开游戏并停留在主界面，运行脚本。

## H5 界面（WebView）

配置界面已从静态 XML（`界面/saoif.ui`，保留作后备）迁移为 H5（WebView）实现：

| 文件 | 说明 |
| :--- | :--- |
| `脚本/ui/h5_page.lua` | **H5 页面源码（唯一来源）**：HTML/CSS/JS 以 UTF-8 长字符串内嵌，直接编辑此文件 |
| `脚本/ui/h5_bridge.lua` | WebView 窗口管理 + Lua ↔ JS 变量通道（Base64(JSON) 协议）+ 实时校验 + 配置持久化 |
| `脚本/saoif.lua` | 主流程：组装功能列表/初值 → 打开 H5 界面 → Lua 侧校验 → 分发任务 |
| `脚本/tasks/fishing.lua` | 任务模块提供 `name` / `desc` / `defaults`，界面功能卡片与默认值由此自动生成 |

> 为什么内嵌：脚本运行时项目文件不在设备工作目录中（已验证不可读），
> 页面需由 Lua 写入 `sdcard/saoif_h5_page.html` 后再由 WebView 加载。
> 若 `界面/` 下出现同名 HTML 副本，属于 IDE 自动生成，请忽略，以 `脚本/ui/h5_page.lua` 为准。

> 功能列表自动来自 `dispatcher`：目前含「钓鱼」「小地图调试」「副本出口」，
> 各任务模块的 `desc` / `defaults` 会自动呈现在功能卡片与参数初值中（无参数的任务用其内置默认值）。

### 变量通道

- JS → Lua：`window.bridge.callLua("__h5_onMessage('<base64>')")`
- Lua → JS：`ui.callJs(web, "javascript:APP.recv('<base64>')")`
- 消息类型：`ready / ack / change / submit / cancel / ping / probe / jserror` ↔ `init / hint / error / pong`
- 每次运行使用唯一窗口名 + 会话号（sid）：上次运行残留页面的事件会被忽略
- 初值下发带 ack + 重发，页面重建也不会丢初始化数据

### 连通性自检

1. 在设备上创建空标记文件 `/sdcard/saoif_h5_autotest`（可用文件管理器或任意脚本创建）
2. 运行脚本：界面会模拟「切页 → 改参数 → 保存并运行」，日志打印回传的完整配置，随后自动删除标记
3. 也可在界面右上角点击【连通自检】：Ping/Pong 往返并在底栏显示 Lua 时间与当前变量

### 配置持久化

点击【保存并运行】后，完整配置保存到 `/sdcard/saoif_h5_config.json`，下次启动自动带出。

## 注意事项

- 游戏界面语言请保持为繁体中文，否则图像识别可能失效。
- 模拟器分辨率请保持固定，脚本按固定分辨率设计。
- 脚本仅供学习交流使用，请自行评估使用自动化脚本带来的账号风险。
- 7x24 挂机建议使用云手机，避免长时间占用本地设备。

## 脚本目录约定（2026-09-30 起）

任务与配置改为「**变量与逻辑分离**」：界面（H5）直接读变量文件自动渲染表单，**新增任务/参数不需要改界面代码**。

### 目录结构

```
脚本/
├── saoif.lua                 入口：自动发现 → 校验 → 分发（从 package.path 解析脚本根）
├── config/                   全局配置（非任务，界面「设置」分区）
│   ├── app.lua               运行与调试（记住配置 / 详细日志）
│   ├── control.lua           移动与转向（摇杆中心、推杆偏置、拖拽px每度）
│   └── vision.lua            视觉阈值（视野锥 / 角色朝向 / 出口模板门限）
├── tasks/                    任务（界面「功能」分区）
│   ├── index.lua             清单兜底（lfs.dir 不可用时使用，新增任务记得补一行）
│   ├── fishing/
│   │   ├── main.lua          逻辑：readConfig / run
│   │   └── vars.lua          变量：id/name/desc/order/defaults/schema（纯数据）
│   ├── minimap/{main,vars}.lua
│   └── dungeon_exit/{main,vars}.lua
└── core/                     纯逻辑库（不含用户变量）
    ├── dispatcher / logger / popup / pixel / move / templates
    ├── minimap / viewcone / viewcone_at / facing / facing_calib
    └── exit / exit_auto
```

### 写一个任务（三步）

1. 建目录 `脚本/tasks/<id>/`
2. `vars.lua` —— **只写数据，不 require、不写函数**（H5 侧用 fengari 执行它生成表单）：
   ```lua
   return {
       id = "my_task", name = "我的任务", desc = "一句话说明", order = 40,
       defaults = { durationS = 60, mode = "auto", showHud = true },
       schema = {
           { key = "durationS", label = "时长(秒)", type = "int",  min = 5, max = 600, step = 5 },
           { key = "mode",      label = "模式",     type = "enum", options = { "auto", "manual" } },
           { key = "showHud",   label = "显示 HUD", type = "bool" },
       },
   }
   ```
   `type` 支持 `int` / `number` / `enum` / `bool` / `text`，可带 `min` / `max` / `step` / `tip` / `options`。
3. `main.lua` —— 逻辑，两行接上变量，实现 `readConfig(cfg)` 与 `run(cfg)`：
   ```lua
   local vars = require("tasks.my_task.vars")
   local logger = require("core.logger")
   local M = { name = vars.name }
   M.id, M.name, M.desc, M.schema, M.defaults = vars.id, vars.name, vars.desc, vars.schema, vars.defaults

   function M.readConfig(cfg)     -- 必须真正读 cfg，缺省回退 M.defaults
       cfg = cfg or {}; local d = M.defaults
       local function num(k) local v = tonumber(cfg[k]); if v == nil then v = d[k] end; return v end
       return { durationS = num("durationS"), mode = tostring(cfg.mode or d.mode), showHud = cfg.showHud ~= false }
   end

   function M.run(cfg) ... end
   return M
   ```
   文件放好后**无需改动入口**：`saoif.lua` 会自动发现（`lfs.dir` 列目录 → `require("tasks.<id>.main")`）。

### 写一个全局配置

同结构，放在 `脚本/config/<name>.lua`，多一个可选的 `apply(v)`：启动时把界面上的值灌回对应模块。

```lua
return {
    id = "control", group = "全局", name = "移动与转向", order = 20,
    defaults = { centerX = 164, pxPerDeg = 2.5 },
    schema = { { key = "centerX", label = "摇杆中心 X", type = "int", min = 0, max = 1280 } },
    apply = function(v)
        local mv = require("core.move")
        mv.CFG.centerX = v.centerX
        require("core.exit").CFG.pxPerDeg = v.pxPerDeg
    end,
}
```
启动顺序：模块默认值 → 界面保存值（`/sdcard/saoif_h5_config.json`）→ `apply()` 灌回模块 → 下发界面初值。

### 注意

- `vars.lua` 里**不要写函数或 require**（会被 fengari 求值失败，`npm run sync` 会报错）
- 配置值目前是**扁平存储**，不同任务请避免同名字段（例如小地图用 `mmShowHud` 与钓鱼的 `showHud` 区分）；`func` 是各任务共用的"当前功能指针"
- 界面（H5）源码在独立仓库 `saoif-h5`：改完执行 `npm run build`，产物会自动写入本项目的 `脚本/ui/h5_page.lua`
