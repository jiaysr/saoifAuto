-- 脚本/ui/h5_page.lua
-- 【自动生成】源文件：界面/saoif_h5.html
-- 修改界面请编辑源文件，然后按 README 的 H5 界面章节重新生成
local M = {}

M.html = [====[
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>SAOIF 自动助手</title>
<style>
  :root {
    --bg1:#0b1220; --bg2:#101c33; --card:#16233c; --card2:#1c2c49; --line:#2b3d5f;
    --txt:#e8eefb; --dim:#8fa3c4; --acc:#4c9bf0; --acc2:#3b82f6;
    --ok:#39d98a; --warn:#f5b83d; --err:#f4655f;
  }
  * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
  html,body { margin:0; height:100%; }
  body {
    background:radial-gradient(1200px 600px at 15% -10%, #1b3160 0%, transparent 55%),
               linear-gradient(160deg,var(--bg1),var(--bg2));
    color:var(--txt); font:13px/1.5 -apple-system,"Noto Sans SC","Microsoft YaHei",sans-serif;
    -webkit-user-select:none; user-select:none; overflow:hidden;
  }
  .app { display:flex; flex-direction:column; height:100%; padding:10px 12px 10px; gap:8px; }

  /* ---------- 顶栏 ---------- */
  header { display:flex; align-items:center; justify-content:space-between; gap:10px; flex:0 0 auto; }
  .brand { display:flex; align-items:center; gap:9px; min-width:0; }
  .logo {
    width:30px; height:30px; border-radius:9px; flex:0 0 auto;
    background:linear-gradient(135deg,#4c9bf0,#7c5cf0); color:#fff;
    display:flex; align-items:center; justify-content:center; font-weight:700; font-size:11px; letter-spacing:.5px;
  }
  .title { font-size:15px; font-weight:600; white-space:nowrap; }
  .title small { color:var(--dim); font-weight:400; font-size:11px; margin-left:4px; }
  .status { display:flex; align-items:center; gap:7px; color:var(--dim); font-size:12px; }
  .dot { width:8px; height:8px; border-radius:50%; background:var(--warn); box-shadow:0 0 0 3px rgba(245,184,61,.15); flex:0 0 auto; }
  .dot.ok { background:var(--ok); box-shadow:0 0 0 3px rgba(57,217,138,.15); }
  .dot.err { background:var(--err); box-shadow:0 0 0 3px rgba(244,101,95,.15); }
  .ghost {
    background:transparent; color:var(--dim); border:1px solid var(--line);
    border-radius:8px; padding:5px 10px; font-size:12px; cursor:pointer;
  }
  .ghost:active { background:rgba(255,255,255,.06); }

  /* ---------- 标签页 ---------- */
  nav { display:flex; gap:6px; background:rgba(255,255,255,.04); padding:4px; border-radius:11px; flex:0 0 auto; }
  .tab {
    flex:1; border:0; background:transparent; color:var(--dim); font-size:13px;
    padding:7px 4px; border-radius:8px; cursor:pointer; font-family:inherit;
  }
  .tab.active { background:linear-gradient(180deg,#2f66b8,#27538f); color:#fff; font-weight:600; }

  /* ---------- 内容区 ---------- */
  main { flex:1 1 auto; min-height:0; position:relative; }
  .panel { position:absolute; inset:0; overflow-y:auto; display:none; padding-right:2px; }
  .panel.active { display:block; }
  .panel::-webkit-scrollbar { width:5px; }
  .panel::-webkit-scrollbar-thumb { background:var(--line); border-radius:3px; }

  .hint { color:var(--dim); font-size:12px; margin:2px 0 8px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(230px,1fr)); gap:8px; align-items:start; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:10px 12px; }
  .card h3 { margin:0 0 8px; font-size:13px; color:var(--acc); font-weight:600; }
  .card h3 .tag { color:var(--dim); font-size:11px; font-weight:400; margin-left:4px; }
  label { display:flex; align-items:center; justify-content:space-between; gap:8px; margin:7px 0 0; font-size:13px; }
  label input[type=number] {
    width:96px; flex:0 0 auto; background:var(--card2); color:var(--txt);
    border:1px solid var(--line); border-radius:8px; padding:6px 8px; font-size:13px;
    font-family:inherit; text-align:right; outline:none;
  }
  label input[type=number]:focus { border-color:var(--acc); }
  .note { color:var(--dim); font-size:11px; margin-top:3px; }
  .check { justify-content:flex-start; gap:8px; }
  .check input { width:17px; height:17px; accent-color:var(--acc2); }

  /* 功能选择卡片 */
  .tasks { display:grid; grid-template-columns:repeat(auto-fit,minmax(200px,1fr)); gap:8px; }
  .task {
    background:var(--card); border:1px solid var(--line); border-radius:12px;
    padding:11px 12px; cursor:pointer; display:flex; align-items:center; gap:10px;
  }
  .task .radio { width:15px; height:15px; border-radius:50%; border:2px solid var(--line); flex:0 0 auto; }
  .task.on { border-color:var(--acc); background:linear-gradient(180deg,#1d3560,#1a2b49); }
  .task.on .radio { border-color:var(--acc); background:radial-gradient(circle at center,var(--acc) 0 45%,transparent 46%); }
  .task b { font-size:13px; }
  .task small { display:block; color:var(--dim); font-size:11px; margin-top:2px; }
  .desc {
    margin-top:8px; background:rgba(76,155,240,.08); border:1px dashed rgba(76,155,240,.4);
    border-radius:10px; padding:9px 11px; color:#cfe0fb; font-size:12px;
  }

  /* 使用说明 */
  .help h3 { margin:0 0 8px; font-size:13px; color:var(--acc); }
  .help ol, .help ul { margin:0; padding-left:18px; color:#cdd9ee; font-size:12.5px; }
  .help li { margin:5px 0; }

  /* ---------- 底栏 ---------- */
  footer { flex:0 0 auto; display:flex; align-items:center; gap:10px; }
  .msg {
    flex:1 1 auto; min-width:0; font-size:12px; color:var(--dim);
    background:rgba(255,255,255,.04); border:1px solid transparent; border-radius:9px;
    padding:8px 10px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;
  }
  .msg.ok { color:var(--ok); }
  .msg.warn { color:var(--warn); }
  .msg.err { color:var(--err); }
  .btns { display:flex; gap:8px; flex:0 0 auto; }
  .btns button { font-family:inherit; font-size:13px; border-radius:9px; padding:9px 16px; cursor:pointer; border:1px solid var(--line); }
  #btnExit { background:transparent; color:var(--dim); }
  #btnRun { background:linear-gradient(180deg,#3f8ae0,#2f6dc4); color:#fff; border-color:transparent; font-weight:600; }
  #btnRun:active { filter:brightness(.92); }
</style>
</head>
<body>
<div class="app">
  <header>
    <div class="brand">
      <div class="logo">SAO</div>
      <div class="title">自动助手<small id="ver">H5</small></div>
    </div>
    <div class="status">
      <span class="dot" id="dot"></span><span id="conn">等待 Lua 连接…</span>
      <button class="ghost" id="btnSelfTest">连通自检</button>
    </div>
  </header>

  <nav>
    <button class="tab active" data-tab="func">功能选择</button>
    <button class="tab" data-tab="fish">钓鱼设置</button>
    <button class="tab" data-tab="help">使用说明</button>
  </nav>

  <main>
    <section class="panel active" id="tab-func">
      <div class="hint">① 选择要运行的功能，启动前必须选择一个。</div>
      <div class="tasks" id="taskList"></div>
      <div class="desc" id="taskDesc">等待 Lua 下发功能列表…</div>
    </section>

    <section class="panel" id="tab-fish">
      <div class="grid">
        <div class="card">
          <h3>运行参数</h3>
          <label>单轮超时(秒) <input type="number" inputmode="numeric" id="loopTime" data-key="loopTime" min="5" max="3600"></label>
          <div class="note">无操作多久后结束，成功会重置计时</div>
          <label>目标次数 <input type="number" inputmode="numeric" id="maxCatch" data-key="maxCatch" min="0" max="9999"></label>
          <div class="note">达到后停止，0 = 不限制</div>
        </div>
        <div class="card">
          <h3>坐标配置 <span class="tag">基准 1280x720</span></h3>
          <label>按钮 X <input type="number" inputmode="numeric" id="clickX" data-key="clickX" min="0" max="1280"></label>
          <label>按钮 Y <input type="number" inputmode="numeric" id="clickY" data-key="clickY" min="0" max="720"></label>
          <div class="note">开始 / 提竿按钮坐标</div>
          <label>扫描列 X <input type="number" inputmode="numeric" id="scanX" data-key="scanX" min="0" max="1280"></label>
          <label>扫描区 Y1 <input type="number" inputmode="numeric" id="zoneY1" data-key="zoneY1" min="0" max="720"></label>
          <label>扫描区 Y2 <input type="number" inputmode="numeric" id="zoneY2" data-key="zoneY2" min="0" max="720"></label>
          <div class="note">用于检测完美区域与浮标位置</div>
        </div>
        <div class="card">
          <h3>高级选项</h3>
          <label class="check"><input type="checkbox" id="showHud" data-key="showHud"><span>屏幕显示运行状态 HUD</span></label>
          <label class="check"><input type="checkbox" id="debugColors" data-key="debugColors"><span>启动时输出颜色采样调试信息</span></label>
        </div>
      </div>
    </section>

    <section class="panel help" id="tab-help">
      <div class="card" style="margin-bottom:8px">
        <h3>使用流程</h3>
        <ol>
          <li>进入游戏钓鱼界面，钓场状态栏保持可见</li>
          <li>本页【功能选择】中选择要运行的功能</li>
          <li>按需在【钓鱼设置】中调整参数</li>
          <li>点击右下角【保存并运行】，窗口关闭后自动运行</li>
          <li>日志见 IDE 输出面板，悬浮按钮可随时停止</li>
        </ol>
      </div>
      <div class="card">
        <h3>注意事项</h3>
        <ul>
          <li>坐标基于 1280x720，其他分辨率请换算</li>
          <li>保持屏幕常亮，不要遮挡游戏窗口</li>
          <li>配置会保存到 sdcard，下次启动自动带出</li>
          <li>本界面为 H5(WebView) 实现，Lua 与网页变量实时互通</li>
        </ul>
      </div>
    </section>
  </main>

  <footer>
    <div class="msg" id="msg">Lua ↔ H5 通道初始化中…</div>
    <div class="btns">
      <button id="btnExit">退出</button>
      <button id="btnRun">保存并运行</button>
    </div>
  </footer>
</div>

<script>
/* ============================================================
 * SAOIF 助手 H5 界面
 * 与 Lua 的变量通道（Base64(JSON) 协议）：
 *   Lua -> JS : ui.callJs("javascript:APP.recv('<base64>')")
 *              消息: {type:'init'|'hint'|'error'|'pong', ...}
 *   JS  -> Lua: window.bridge.callLua("__h5_onMessage('<base64>')")
 *              消息: {type:'ready'|'ack'|'change'|'submit'|'cancel'|'ping', ...}
 * ============================================================ */
var APP = (function () {
  var state = {
    values: {},        // 当前表单值
    tasks: [],         // 功能列表 [{name, desc}]
    func: '',          // 当前选择的功能
    ready: false,      // 页面就绪（尺寸有效）
    luaAlive: false,   // 已收到 Lua 的 init
    pingSentAt: 0
  };
  var readyTries = 0;

  var $ = function (id) { return document.getElementById(id); };

  /* ---------- Base64(UTF-8) 编解码 ---------- */
  function b64encode(s) { return btoa(unescape(encodeURIComponent(s))); }
  function b64decode(s) {
    s = String(s).replace(/[^A-Za-z0-9+/=]/g, '');   // 容忍折行/空白
    while (s.length % 4) { s += '='; }
    return decodeURIComponent(escape(atob(s)));
  }

  /* ---------- 与 Lua 通信 ---------- */
  function toLua(msg) {
    try {
      if (msg.type !== 'ready' && state.sid) { msg.sid = state.sid; }
      if (window.bridge && typeof window.bridge.callLua === 'function') {
        window.bridge.callLua("__h5_onMessage('" + b64encode(JSON.stringify(msg)) + "')");
        return true;
      }
    } catch (e) { setMsg('调用 Lua 失败: ' + e.message, 'err'); }
    return false;
  }

  /* ---------- 状态显示 ---------- */
  function setMsg(text, cls) {
    var el = $('msg');
    el.textContent = text;
    el.className = 'msg' + (cls ? ' ' + cls : '');
  }
  function setConn(text, cls) {
    var d = $('dot');
    d.className = 'dot' + (cls ? ' ' + cls : '');
    $('conn').textContent = text;
  }

  /* ---------- 表单读写 ---------- */
  var NUM_KEYS = { loopTime:1, maxCatch:1, clickX:1, clickY:1, scanX:1, zoneY1:1, zoneY2:1 };
  var BOOL_KEYS = { showHud:1, debugColors:1 };

  function applyValues(v) {
    if (!v) { return; }
    Object.keys(v).forEach(function (k) {
      state.values[k] = v[k];
      var el = $(k);
      if (!el) { return; }
      if (BOOL_KEYS[k]) { el.checked = !!v[k]; }
      else if (NUM_KEYS[k]) { el.value = (v[k] === null || v[k] === undefined) ? '' : v[k]; }
    });
  }

  function collect() {
    var out = { func: state.func };
    Object.keys(NUM_KEYS).forEach(function (k) {
      var el = $(k);
      var n = parseFloat(el.value);
      out[k] = isFinite(n) ? n : null;
    });
    Object.keys(BOOL_KEYS).forEach(function (k) { out[k] = !!$(k).checked; });
    return out;
  }

  /* ---------- 功能选择 ---------- */
  function renderTasks() {
    var box = $('taskList');
    box.innerHTML = '';
    if (!state.tasks.length) {
      box.innerHTML = '<div class="hint">Lua 未下发功能列表</div>';
      return;
    }
    state.tasks.forEach(function (t) {
      var el = document.createElement('div');
      el.className = 'task' + (state.func === t.name ? ' on' : '');
      el.innerHTML = '<span class="radio"></span><span><b></b><small></small></span>';
      el.querySelector('b').textContent = t.name;
      el.querySelector('small').textContent = t.desc || '';
      el.addEventListener('click', function () {
        state.func = t.name;
        state.values.func = t.name;
        renderTasks();
        $('taskDesc').textContent = t.desc || t.name;
        onFieldChange('func', t.name);
      });
      box.appendChild(el);
    });
    var cur = state.tasks.filter(function (t) { return t.name === state.func; })[0];
    $('taskDesc').textContent = cur ? (cur.desc || cur.name)
                                    : '请选择一个功能，未选择将无法启动。';
  }

  /* ---------- 字段变化：实时同步给 Lua（批量发送，保证每个字段都上报） ---------- */
  var pendingChanges = {};
  var changeTimer = null;
  function onFieldChange(key, value) {
    if (!state.luaAlive) { return; }
    pendingChanges[key] = value;
    if (changeTimer) { clearTimeout(changeTimer); }
    changeTimer = setTimeout(function () {
      Object.keys(pendingChanges).forEach(function (k) {
        toLua({ type: 'change', key: k, value: pendingChanges[k] });
      });
      pendingChanges = {};
    }, 180);
  }

  /* ---------- 接收 Lua 消息 ---------- */
  function onLuaMsg(msg) {
    switch (msg.type) {
      case 'init':
        state.sid = msg.data.sid || state.sid;
        state.tasks = msg.data.tasks || [];
        if (msg.data.values && msg.data.values.func) { state.func = msg.data.values.func; }
        else if (state.tasks.length) { state.func = state.tasks[0].name; }
        applyValues(msg.data.values || {});
        renderTasks();
        state.luaAlive = true;
        setConn('Lua 已连接', 'ok');
        setMsg('变量通道就绪 · 界面版本 ' + (msg.data.ver || '-'), 'ok');
        toLua({ type: 'ack' });
        break;
      case 'hint':
        setMsg(msg.data.text, msg.data.level || 'warn');
        break;
      case 'error':
        setMsg(msg.data.text, 'err');
        break;
      case 'pong':
        var rtt = Date.now() - (msg.data && msg.data.t);
        setMsg('自检通过 · 往返 ' + rtt + 'ms · Lua 时间 ' + msg.data.luaTime
               + ' · 变量 ' + msg.data.func + '/' + msg.data.loopTime + 's', 'ok');
        break;
      default:
        break;
    }
  }

  /* ---------- 接收 Lua 消息（带异常回收，出错回报 Lua） ---------- */
  function onLuaRecv(b64) {
    try {
      onLuaMsg(JSON.parse(b64decode(b64)));
    } catch (e) {
      toLua({ type: 'jserror', text: String((e && e.message) || e) });
    }
  }

  /* ---------- 探针：验证 Lua->JS 通道 ---------- */
  function probe(t, sid) { toLua({ type: 'probe', text: String(t), sid: String(sid || '') }); }

  /* ---------- 页面就绪探测（WebView 布局前 innerWidth=0） ---------- */
  function probeSize() {
    if (state.ready) { return; }
    if (window.innerWidth > 0 && window.innerHeight > 0) {
      state.ready = true;
      setMsg('页面已就绪，等待 Lua 下发变量…');
      toLua({ type: 'ready' });
      keepaliveReady();
      return;
    }
    setTimeout(probeSize, 200);
  }

  /* 在收到 init 前周期性重发 ready：
     防止 WebView 重建页面实例后 Lua 侧收不到就绪信息 */
  function keepaliveReady() {
    var iv = setInterval(function () {
      if (state.luaAlive || ++readyTries > 8) { clearInterval(iv); return; }
      toLua({ type: 'ready' });
    }, 2500);
  }

  /* ---------- 事件绑定 ---------- */
  function bind() {
    document.querySelectorAll('.tab').forEach(function (t) {
      t.addEventListener('click', function () {
        document.querySelectorAll('.tab').forEach(function (x) { x.classList.remove('active'); });
        document.querySelectorAll('.panel').forEach(function (x) { x.classList.remove('active'); });
        t.classList.add('active');
        $('tab-' + t.dataset.tab).classList.add('active');
      });
    });

    document.querySelectorAll('input[data-key]').forEach(function (el) {
      var key = el.dataset.key;
      el.addEventListener('change', function () {
        var v = (el.type === 'checkbox') ? !!el.checked : parseFloat(el.value);
        if (!isFinite(v) && el.type !== 'checkbox') { v = null; }
        state.values[key] = v;
        onFieldChange(key, v);
      });
    });

    $('btnRun').addEventListener('click', function () {
      var cfg = collect();
      // 本地快速校验（Lua 端仍会做权威校验）
      if (!cfg.func) { setMsg('请先在【功能选择】中选择一个功能', 'err'); return; }
      for (var k in NUM_KEYS) {
        if (cfg[k] === null) { setMsg('参数填写不完整: ' + k, 'err'); return; }
      }
      if (cfg.clickX < 0 || cfg.clickX > 1280 || cfg.clickY < 0 || cfg.clickY > 720) {
        setMsg('按钮坐标超出 1280x720 基准范围', 'err'); return;
      }
      if (cfg.zoneY2 <= cfg.zoneY1) { setMsg('扫描区 Y2 必须大于 Y1', 'err'); return; }
      setMsg('已提交，等待 Lua 校验…');
      toLua({ type: 'submit', data: cfg });
    });

    $('btnExit').addEventListener('click', function () {
      toLua({ type: 'cancel' });
      setMsg('正在退出…');
    });

    $('btnSelfTest').addEventListener('click', function () {
      if (!state.luaAlive) { setMsg('Lua 尚未连接，无法自检', 'err'); return; }
      state.pingSentAt = Date.now();
      toLua({ type: 'ping', t: state.pingSentAt });
      setMsg('自检请求已发送…');
    });
  }

  /* ---------- 自检：由 Lua 触发，模拟"切页 → 改参数 → 点保存并运行" ---------- */
  function autoTest() {
    setTimeout(function () { document.querySelector('.tab[data-tab="fish"]').click(); }, 1000);
    setTimeout(function () {
      var lt = $('loopTime');
      lt.value = 3;
      lt.dispatchEvent(new Event('change'));
      var cx = $('clickX');
      cx.value = 1200;
      cx.dispatchEvent(new Event('change'));
    }, 3000);
    setTimeout(function () { $('btnRun').click(); }, 14000);
  }

  document.addEventListener('DOMContentLoaded', function () {
    bind();
    if (!(window.bridge && window.bridge.callLua)) {
      setConn('bridge 缺失', 'err');
      setMsg('window.bridge 不可用，无法与 Lua 通信', 'err');
    }
    probeSize();
  });

  return { recv: onLuaRecv, autoTest: autoTest, probe: probe, state: state };
})();
</script>
</body>
</html>

]====]

return M
