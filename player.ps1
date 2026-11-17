#requires -version 5.1
<#
  网课视频后台播放助手  —— 纯 PowerShell 实现，零第三方依赖
  仅用 Windows 自带 PowerShell 5.1 + .NET，脱离任何 AI 工具独立运行。
#>
param(
    [string]$Action = "",
    [string]$Url = "",
    [int]$Port = 9222,
    [string]$ProfileDir = "",
    [int]$Interval = 10000,
    [double]$Speed = 1.0,
    [switch]$NoMute
)

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if (-not $ProfileDir) { $ProfileDir = Join-Path $env:TEMP "KaoKePlayer\profile" }   # 程序独立的浏览器配置（登录态存在这里，与其他工具无关）
$script:cdpId = 1
$script:MUTE = -not $NoMute
$script:Speed = $Speed
$script:ScriptPath = $PSCommandPath
# 浏览器允许的倍速上限（多数平台 16 封顶，超出浏览器会自动钳制）
if ($script:Speed -le 0) { $script:Speed = 1.0 }
$script:CdpEvents = @()
# 通用 video 查找器：穿透 iframe 由 CDP 执行上下文处理，这里额外穿透 Shadow DOM
$script:FIND_JS = "(()=>{function w(r){let a=[];try{a=a.concat([...r.querySelectorAll('video')]);}catch(e){}try{const es=r.querySelectorAll('*');for(let i=0;i<es.length;i++){if(es[i].shadowRoot)a=a.concat(w(es[i].shadowRoot));}}catch(e){}return a;}const vs=w(document);"

function Log([string]$m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m) }
function Fail([string]$m) { Write-Host ("[错误] " + $m) -ForegroundColor Red }

# ---------- 找浏览器 ----------
function Find-Browser {
    $c = @(
        'C:\Program Files\Google\Chrome\Application\chrome.exe',
        'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
        'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
        (Join-Path $env:LOCALAPPDATA '360ChromeX\Chrome\Application\360ChromeX.exe')
    )
    foreach ($p in $c) { if (Test-Path $p) { return $p } }
    return $null
}

# ---------- HTTP ----------
function Get-Json([string]$path, [int]$timeout = 3) {
    try {
        $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}{1}" -f $Port, $path) `
             -UseBasicParsing -TimeoutSec $timeout
        return ($r.Content | ConvertFrom-Json)
    } catch { return $null }
}
function Wait-Cdp([int]$tries = 50) {
    for ($i = 0; $i -lt $tries; $i++) {
        $v = Get-Json '/json/version' 2
        if ($v) { return $v }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

# ---------- CDP over WebSocket ----------
function Cdp-Connect([string]$wsUrl) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ct = [System.Threading.CancellationToken]::None
    $ws.ConnectAsync([uri]$wsUrl, $ct).GetAwaiter().GetResult() | Out-Null
    return $ws
}
function Cdp-Send($ws, [hashtable]$obj) {
    $json = $obj | ConvertTo-Json -Compress -Depth 12
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [System.ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
                  [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
}
function Cdp-Recv($ws) {
    $buf = New-Object byte[] 2097152
    $sb = New-Object System.Text.StringBuilder
    do {
        $seg = [System.ArraySegment[byte]]::new($buf)
        $res = $ws.ReceiveAsync($seg, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
        if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
        [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
    } while (-not $res.EndOfMessage)
    return $sb.ToString()
}
function Invoke-Cdp($ws, [string]$method, [hashtable]$params, [int]$timeoutSec = 30) {
    $id = $script:cdpId; $script:cdpId++
    Cdp-Send $ws @{ id = $id; method = $method; params = $params }
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $raw = Cdp-Recv $ws
        if (-not $raw) { continue }
        try { $o = $raw | ConvertFrom-Json } catch { continue }
        # 事件消息（含 iframe 上下文创建）先记下来，供查找播放器用
        # 只保留上下文创建事件：长跑数小时时避免事件数组无限增长（内存泄漏）
        if ($o.method -and -not $o.id) {
            if ($o.method -eq 'Runtime.executionContextCreated') {
                $script:CdpEvents += $o
                if ($script:CdpEvents.Count -gt 300) { $script:CdpEvents = @($script:CdpEvents | Select-Object -Last 200) }
            }
            continue
        }
        if ($o.id -eq $id) { return $o }
    }
    return $null
}
# 多标签时选对页面：遍历所有 http 页签，返回真正带 video 的那个；
# 都没有则退回第一个页签（用于打开新链接）。
function Get-VideoTab {
    $tabs = Get-Json '/json/list'
    if (-not $tabs) { return $null }
    $pages = @($tabs | Where-Object { $_.type -eq 'page' -and $_.url -match '^https?://' })
    foreach ($t in $pages) {
        try {
            $ws = Cdp-Connect $t.webSocketDebuggerUrl
            $cid = Find-VideoContext $ws
            $ws.Dispose()
            if ($null -ne $cid) { return $t }
        } catch { }
    }
    return ($pages | Select-Object -First 1)
}
function Eval-Js($ws, [string]$expr, $contextId = $null) {
    $p = @{ expression = $expr; returnByValue = $true; awaitPromise = $true }
    if ($contextId) { $p.contextId = $contextId }
    $r = Invoke-Cdp $ws 'Runtime.evaluate' $p
    return $r.result.result.value
}
# 收集所有 frame 的执行上下文 ID（包含跨域 iframe），用于穿透播放器嵌套
function Get-ContextIds($ws) {
    $ids = @()
    # Runtime.enable 后会推送每个 frame 的 executionContextCreated 事件
    Invoke-Cdp $ws 'Runtime.enable' @{} | Out-Null
    Start-Sleep -Milliseconds 600
    foreach ($e in $script:CdpEvents) {
        if ($e.method -eq 'Runtime.executionContextCreated' -and $e.params.context.id) {
            $ids += $e.params.context.id
        }
    }
    $ids = @($ids)
    if ($ids.Count -eq 0) { $ids += 0 }   # 0 = 默认主上下文
    return @($ids | Select-Object -Unique)
}
# 在任意 frame 中查找 video，返回一个可用的上下文 ID；找不到返回 $null
function Find-VideoContext($ws) {
    $ids = Get-ContextIds $ws
    $probe = $script:FIND_JS + "return vs.length;})()"
    foreach ($cid in $ids) {
        try {
            $n = Eval-Js $ws $probe $cid
            if ($null -ne $n -and [int]$n -gt 0) { return $cid }
        } catch {}
    }
    return $null
}
function Set-Window([string]$targetId, [string]$state) {
    try {
        $ver = Get-Json '/json/version'
        $ws = Cdp-Connect $ver.webSocketDebuggerUrl
        $w = Invoke-Cdp $ws 'Browser.getWindowForTarget' @{ targetId = $targetId }
        if ($w.result.windowId) {
            Invoke-Cdp $ws 'Browser.setWindowBounds' @{
                windowId = $w.result.windowId
                bounds = @{ windowState = $state }
            } | Out-Null
        }
        $ws.Dispose()
    } catch {}
}

# ---------- 无头模式开关（浏览器完全隐形，省资源防卡顿）----------
# 存在 flag 文件即开启。开启前请先在显示模式下完成登录。
function Get-Headless { Test-Path (Join-Path $ProfileDir 'headless.flag') }
function Set-Headless([bool]$on) {
    $f = Join-Path $ProfileDir 'headless.flag'
    if ($on) { New-Item -ItemType File -Path $f -Force | Out-Null }
    else { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    # 同步更新浏览器启动任务：计划任务启动时也带/不带无头参数
    try {
        $taskName = "KaoKeBrowser_$Port"
        $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($t) {
            $a = $t.Actions[0].Arguments
            if ($on) { if ($a -notmatch '--start-minimized') { $a = "--start-minimized --window-position=-32000,-32000 --window-size=1380,900 " + $a } }
            else { $a = ($a -replace '--start-minimized --window-position=-32000,-32000 --window-size=1380,900 ', '').Trim() }
            $act = New-ScheduledTaskAction -Execute $t.Actions[0].Execute -Argument $a
            Set-ScheduledTask -TaskName $taskName -Action $act | Out-Null
        }
    } catch {}
}

# ---------- 启动浏览器（任务计划，跨会话存活）----------
function Start-Browser([string]$openUrl) {
    if (-not $openUrl) { $openUrl = 'about:blank' }
    $chrome = Find-Browser
    if (-not $chrome) { Fail "未找到 Chrome / Edge / 360ChromeX，请先安装任一浏览器"; return $false }
    New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
    $headArgs = ""
    if (Get-Headless) { $headArgs = "--start-minimized --window-position=-32000,-32000 --window-size=1380,900 " }
    $argLine = $headArgs + "--remote-debugging-port=$Port --user-data-dir=`"$ProfileDir`" --no-first-run " +
               "--no-default-browser-check --disable-popup-blocking " +
               "--autoplay-policy=no-user-gesture-required " +
               "--disable-background-timer-throttling --disable-backgrounding-occluded-windows " +
               "--disable-renderer-backgrounding --disable-features=CalculateNativeWinOcclusion " +
               "`"$openUrl`""
    $task = "KaoKeBrowser_$Port"
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    $act = New-ScheduledTaskAction -Execute $chrome -Argument $argLine
    Register-ScheduledTask -TaskName $task -Action $act -Force | Out-Null
    Start-ScheduledTask -TaskName $task
    Log "浏览器启动中（独立配置，登录一次后长期免登录）..."
    $v = Wait-Cdp
    if (-not $v) { Fail "浏览器未能就绪"; return $false }
    Log ("浏览器就绪：" + $v.Browser)
    return $true
}

# 在视频所在 frame 注入页面内定时器，高频维持倍速
# 关键：既要顶住 video.playbackRate（画面速度），也要顶住播放器 options.speed.value
# ——后者是平台心跳上报倍速(sp)的唯一来源。两者一致，画面进度和平台记账才不会脱节。
function Inject-SpeedKeeper($ws, $cid, [double]$sp) {
    $spStr = [string]$sp
    $expr = $script:FIND_JS + @"
if(!vs.length) return 0;
if(window.__spdTimer) { try{clearInterval(window.__spdTimer)}catch(e){} }
window.__spdTarget = $spStr;
const keep = () => {
  const vs2 = document.querySelectorAll('video');
  for (const v of vs2) { try { if (Math.abs(v.playbackRate - window.__spdTarget) > 0.01) v.playbackRate = window.__spdTarget; } catch(e){} }
  // 雨课堂等平台：播放器把倍速记在 options.speed.value，心跳据此上报 sp
  try {
    const hosts = document.querySelectorAll('div.xtplayer');
    for (const h of hosts) {
      if (!h.__vue__ || !h.__vue__.player) continue;
      const p = h.__vue__.player;
      if (p.options && p.options.speed) {
        p.options.speed.value = window.__spdTarget;
        if (p.heartBeat && p.heartBeat.params) p.heartBeat.params.sp = window.__spdTarget;
      }
      // 同步可见控件状态，避免界面仍显示旧倍速
      const li = document.querySelector('xt-speedbutton li[data-speed="' + window.__spdTarget + '"]');
      const act = document.querySelector('xt-speedbutton li.xt_video_player_common_active');
      const val = document.querySelector('xt-speedbutton xt-speedvalue');
      if (act && act !== li) { act.classList.remove('xt_video_player_common_active'); if (li) li.classList.add('xt_video_player_common_active'); }
      if (val) val.textContent = window.__spdTarget.toFixed(2) + 'X';
    }
  } catch(e){}
  // 中国大学MOOC等平台：倍速按钮显示同步（检测到才启用），让界面显示与实际速度一致
  try {
    const rbtn = document.querySelector('.ratebtn_text');
    const rpop = document.querySelector('.m-popover-rate');
    if (rbtn && rpop) {
      const shown = parseFloat(rbtn.textContent) || 1;
      if (Math.abs(shown - window.__spdTarget) > 0.01) {
        const lis = rpop.querySelectorAll('li.item');
        for (const li of lis) {
          const val = parseFloat(li.textContent.replace(/[^\d.]/g, ''));
          if (Math.abs(val - window.__spdTarget) < 0.01) { li.click(); break; }
        }
      }
    }
  } catch(e){}
};
keep();
window.__spdTimer = setInterval(keep, 100);
return vs.length;
})()
"@
    return Eval-Js $ws $expr $cid
}

# ---------- 边播边同步：让服务端观看记录跟随真实播放位置 ----------
# 注入页面内定时器，每 5 秒把服务端观看进度(last_point)追平到视频当前播放位置。
# 只补不回退、完成即停。视频播到哪服务端记到哪，播完自然判定完成。
# 与一次性 complete 的区别：complete 直接补到结尾；这里跟着画面逐步推进。
function Inject-LiveSync($ws, $cid) {
    $expr = @"
(() => {
  if (window.__liveSync) { clearInterval(window.__liveSync); }
  let busy = false;
  const tick = async () => {
    if (busy) return; busy = true;
    try {
      const host = document.querySelector('div.xtplayer');
      if (!host || !host.__vue__ || !host.__vue__.player) { busy = false; return; }
      const p = host.__vue__.player, o = p.options, hb = p.heartBeat, v = p.video;
      const base = hb ? JSON.parse(JSON.stringify(hb.params)) : null;
      const cid = o.cid || (base && base.c), uid = o.userId || (base && base.u);
      const room = o.classroom_id || (base && base.classroomid), vid = o.id || (base && base.v);
      const curPos = Math.floor((v.currentTime || 0));
      if (!base || !cid || !uid || !room || !vid || curPos < 2) { busy = false; return; }
      const url = '/video-log/get_video_watch_progress/?cid=' + cid + '&user_id=' + uid +
        '&classroom_id=' + room + '&video_type=video&vtype=rate&video_id=' + vid;
      const r = await fetch(url, {credentials:'include'});
      const j = await r.json();
      const rec = (j.data && j.data[vid]) || j[vid];
      if (!rec || rec.completed) { busy = false; return; }
      const last = Math.floor(rec.last_point || 0);
      if (curPos <= last + 3) { busy = false; return; }
      const token = (document.cookie.match(/csrftoken=([^;]+)/) || [])[1] || '';
      const headers = {'Content-Type':'application/json','X-CSRFToken':token,'xtbz':'ykt'};
      let target = (o.speed && o.speed.value) || 2; if (!(target > 0)) target = 2;
      const data = []; let cp = last + 1, sq = (base.sq || 0) + 1000; const tsBase = Date.now();
      while (cp <= curPos && data.length < 200) {
        const one = JSON.parse(JSON.stringify(base));
        one.et = 'heartbeat'; one.cp = cp; one.sp = target;
        one.ts = (tsBase + sq * 3000) + ''; one.sq = sq++;
        data.push(one); cp += 6;
      }
      await fetch('/video-log/heartbeat/', {
        method:'POST', credentials:'include', headers,
        body: JSON.stringify({heart_data: data})
      });
    } catch (e) {}
    busy = false;
  };
  window.__liveSync = setInterval(tick, 5000);
  return true;
})()
"@
    return Eval-Js $ws $expr $cid
}

# ---------- 登录检测 ----------
function Check-Login {
    $p = Get-VideoTab
    if (-not $p) { return @{ ok = $false; reason = 'no_page' } }
    $ws = Cdp-Connect $p.webSocketDebuggerUrl
    Invoke-Cdp $ws 'Runtime.enable' @{} | Out-Null
    $s = Eval-Js $ws "({url:location.href,title:document.title})"
    $cid = Find-VideoContext $ws
    $n = 0
    if ($null -ne $cid) {
        $n = Eval-Js $ws ($script:FIND_JS + "return vs.length;})()") $cid
    }
    $ws.Dispose()
    # 通用判断：任意 frame 出现 video 即视为进入播放页（不依赖任何平台的登录URL）
    return @{ ok = ([int]$n -gt 0); url = $s.url; title = $s.title; videos = [int]$n; contextId = $cid }
}

# ---------- 播放 ----------
function Start-Playback([string]$videoUrl) {
    $script:LastUrl = $videoUrl   # 记住本次播放的页面，浏览器意外关闭后自动重启回到这里
    if (-not (Wait-Cdp 2)) {
        if (-not (Start-Browser $videoUrl)) { return $false }
        if (-not $videoUrl) { Log "浏览器已启动。请在里面登录课程平台并打开视频页，然后本程序自动继续。" }
    } elseif ($videoUrl) {
        $p = Get-VideoTab
        if ($p) {
            $ws = Cdp-Connect $p.webSocketDebuggerUrl
            Invoke-Cdp $ws 'Page.enable' @{} | Out-Null
            Invoke-Cdp $ws 'Page.navigate' @{ url = $videoUrl } | Out-Null
            $ws.Dispose()
            Log "已打开视频链接"
        }
    } else {
        Log "使用当前浏览器里已打开的页面（未粘贴链接）"
    }

    # 等待登录（首次必须在浏览器里人工登录）
    $logged = $false
    for ($i = 0; $i -lt 100; $i++) {
        Start-Sleep -Seconds 3
        # 浏览器被关闭/崩溃 → 自动重启并回到之前的页面
        if (-not (Wait-Cdp 1)) {
            Log "浏览器未运行，自动重新启动..."
            Start-Browser $script:LastUrl | Out-Null
            Start-Sleep -Seconds 3
            continue
        }
        $c = Check-Login
        if ($c.ok) { $logged = $true; if ($c.url) { $script:LastUrl = $c.url }; break }
        if ($i -eq 0) {
            Write-Host ""
            Write-Host "  请在弹出的浏览器窗口里登录课程平台（只需这一次）。" -ForegroundColor Yellow
            Write-Host "  登录并进入视频页面后，本程序会自动继续。—— 等待中（最多5分钟）" -ForegroundColor Yellow
            Write-Host ""
        }
        if ($i % 10 -eq 0) { Log ("等待登录... (" + ($i*3) + "秒) ") }
    }
    if (-not $logged) { Fail "等待登录超时，请重新运行本程序"; return $false }
    Log "登录状态正常，检测到视频播放器"

    $p = Get-VideoTab
    $ws = Cdp-Connect $p.webSocketDebuggerUrl
    Invoke-Cdp $ws 'Runtime.enable' @{} | Out-Null
    $m = if ($script:MUTE) { 'true' } else { 'false' }
    $sp = $script:Speed
    $cid = Find-VideoContext $ws
    # 先前台缓冲到可播放，再最小化（过早最小化会卡在 0 秒）；同时设置倍速
    $playExpr = $script:FIND_JS + "if(vs.length){const v=vs[0];v.muted=$m;v.defaultMuted=$m;try{v.playbackRate=$sp;}catch(e){}v.load();v.play().catch(()=>{});}return vs.length;})()"
    Eval-Js $ws $playExpr $cid | Out-Null
    $ready = $false
    $statExpr = $script:FIND_JS + "const v=vs[0];return v?{t:v.currentTime,d:v.duration,r:v.readyState}:null;})()"
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 2
        $s = Eval-Js $ws $statExpr $cid
        if ($s -and $s.r -ge 3 -and $s.t -gt 0) {
            $ready = $true
            Log ("播放正常：进度 {0}/{1} 秒" -f [math]::Round($s.t), [math]::Round($s.d))
            break
        }
    }
    if (-not $ready) { Log "警告：缓冲较慢，保活程序会持续尝试恢复" }
    # 注入页面内倍速维持器（对抗平台自动重置 playbackRate）
    if ([math]::Abs($script:Speed - 1.0) -gt 0.01) {
        Inject-SpeedKeeper $ws $cid $script:Speed | Out-Null
        Log ("已启用倍速 " + $script:Speed + "x（页面内持续维持）")
    }
    # 注入完成度实时同步（播放过程中把服务端观看记录追平到画面进度）
    Inject-LiveSync $ws $cid | Out-Null
    Log "已启用完成度实时同步（边播边记，播完自动判定完成）"
    Set-Window $p.id 'minimized'
    $ws.Dispose()
    Log "已最小化到后台"

    # 启动保活
    # 保活循环由菜单进程直接运行（菜单'1'里链式调用 Run-WatchLoop），
    # 不再用计划任务方式——避免多弹一个黑窗口、避免双循环重复注入。
    Log "后台播放已就绪。可用菜单 2 随时查看进度。"
    return $true
}

# ---------- 保活（隐藏后台作业：菜单保持可操作，无额外窗口）----------
function Start-WatchJob {
    $inner = "-NoProfile -ExecutionPolicy Bypass -File '$script:ScriptPath' -Action watch -Port $Port -ProfileDir '$ProfileDir' -Interval $Interval -Speed $($script:Speed)"
    if (-not $script:MUTE) { $inner += " -NoMute" }
    $script:WatchJob = Start-Job -Name 'KaoKeWatch' -ScriptBlock { param($cmd) Invoke-Expression $cmd } -ArgumentList $inner
    Log "保活已在后台作业中运行（本菜单随时可操作：2=进度 3=倍速 6=同步 5=停止）。"
}

# ---------- 视频内答题助手（题库积累 + 自动作答，适配中国大学MOOC）----------
# 题库文件：ProfileDir\answers.txt，每行格式：题干关键词|答案字母（如 中国建造的发展目标|A）
# 未答过的题目会记录到 ProfileDir\questions.txt，答完一次后自动入库。
$script:QuizLogged = @{}
function Invoke-QuizTick($ws, $cid) {
    try {
        $st = Eval-Js $ws @"
(() => {
  const box = document.querySelector('.j-unitctBox');
  if (!box || !box.offsetParent) return { none: true };
  const txt = (box.innerText || '');
  if (/你选对了|你选错了|正确答案/.test(txt)) {
    const m = txt.match(/正确答案[：:]\s*([A-Za-z]+)/);
    const links = [...box.querySelectorAll('a, button, div, span')].filter(e => (e.innerText||'').trim() === '继续学习' && e.offsetParent);
    return { answered: true, correct: m ? m[1] : '', wrong: /你选错了/.test(txt), hasContinue: links.length > 0 };
  }
  const btn = box.querySelector('.submit');
  if (!btn || btn.offsetParent === null) return { none: true };
  const lines = txt.split('\n').map(s => s.trim()).filter(s => s.length > 8 && !/^\d{1,2}:\d{2}/.test(s) && !/^\d+(\.\d+)?x?$/i.test(s) && s !== '标清' && s !== '高清' && !/^提交$/.test(s) && !/^[A-Za-z]\./.test(s) && !/^\d+$/.test(s));
  const q = lines.join(' ');
  return { q: q.substring(0, 120) };
})()
"@ $cid
        if (-not $st -or $st.none) { return }
        if ($st.answered) {
            # 已提交：答错则把标准答案学进题库；点"继续学习"恢复播放
            if ($st.wrong -and $st.correct -and $script:QuizPendingQ) {
                $ansFile = Join-Path $ProfileDir 'answers.txt'
                Add-Content -Path $ansFile -Value ($script:QuizPendingQ.Substring(0, [Math]::Min(40, $script:QuizPendingQ.Length)) + '|' + $st.correct) -Encoding UTF8
                Log ("答错了一题，已把标准答案学进题库：" + $st.correct)
                $script:QuizPendingQ = ''
            }
            if ($st.hasContinue) {
                [void](Eval-Js $ws "(() => { const ls = [...document.querySelectorAll('.j-unitctBox a, .j-unitctBox button, .j-unitctBox div, .j-unitctBox span')].filter(e => (e.innerText||'').trim() === '继续学习' && e.offsetParent); if (ls.length) { ls[0].click(); return 1; } return 0; })()" $cid)
                Log "题目已完成，已点继续学习恢复播放"
            }
            return
        }
        $q = $st.q
        if (-not $q) { return }
        # 查题库
        $ansFile = Join-Path $ProfileDir 'answers.txt'
        $letter = ''
        if (Test-Path $ansFile) {
            foreach ($line in (Get-Content $ansFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                $pair = ($line -split '\|', 2)
                if ($pair.Count -eq 2 -and $pair[0].Trim().Length -ge 4 -and $q.Contains($pair[0].Trim())) { $letter = $pair[1].Trim().ToUpper(); break }
            }
        }
        if (-not $letter) {
            # 题库里没有：记录题目，交给用户补充（不乱答）
            if (-not $script:QuizLogged.ContainsKey($q)) {
                $script:QuizLogged[$q] = $true
                Add-Content -Path (Join-Path $ProfileDir 'questions.txt') -Value ((Get-Date -Format 'MM-dd HH:mm') + ' ' + $q) -Encoding UTF8
                Log ("检测到新题目，已记录到 questions.txt（答案请补充到 answers.txt，格式：题干关键词|A）：" + $q)
            }
            return
        }
        # 自动作答 + 提交
        [void](Eval-Js $ws @"
(() => {
  const box = document.querySelector('.j-unitctBox');
  const radios = [...box.querySelectorAll('input[type=radio]')];
  const idx = '$letter'.charCodeAt(0) - 65;
  if (idx < 0 || idx >= radios.length) return 0;
  radios[idx].click();
  return 1;
})()
"@ $cid)
        Start-Sleep -Milliseconds 800
        [void](Eval-Js $ws "(() => { const b = document.querySelector('.j-unitctBox .submit'); if (b && b.offsetParent) { b.click(); return 1; } return 0; })()" $cid)
        $script:QuizPendingQ = $q
        Log ("已自动作答：" + $letter + "（题：" + $q.Substring(0, [Math]::Min(30, $q.Length)) + "...)，等待提交结果")
    } catch {}
}

# ---------- 保活循环 ----------
function Run-WatchLoop {
    if (-not (Wait-Cdp)) { return }
    $p = Get-VideoTab
    if (-not $p) { return }
    $ws = Cdp-Connect $p.webSocketDebuggerUrl
    Invoke-Cdp $ws 'Runtime.enable' @{} | Out-Null
    $m = if ($script:MUTE) { 'true' } else { 'false' }
    $sp = $script:Speed
    $cid = Find-VideoContext $ws
    if ($null -ne $cid -and [math]::Abs($script:Speed - 1.0) -gt 0.01) { Inject-SpeedKeeper $ws $cid $script:Speed | Out-Null }
    if ($null -ne $cid) { Inject-LiveSync $ws $cid | Out-Null }   # 边播边同步完成度
    $keepExpr = $script:FIND_JS + "if(!vs.length)return{no:true};const v=vs[0];if(v.paused||v.currentTime<=0){v.muted=$m;v.play().catch(()=>{});}return{t:Math.round(v.currentTime),d:Math.round(v.duration||0),p:v.paused,r:v.readyState,rate:v.playbackRate,u:location.href};})()"
    Log ("保活启动，间隔 " + $Interval + "ms，倍速 " + $sp + "x")
    $ticks = 0
    while ($true) {
        Start-Sleep -Milliseconds $Interval
        $ticks++
        try {
            $s = Eval-Js $ws $keepExpr $cid
            # 找不到视频（页面刷新/换集/context失效）→ 重新定位
            if (-not $s -or $s.no) {
                $cid = Find-VideoContext $ws
                if ($null -eq $cid) { throw 'context_lost' }
                if ([math]::Abs($script:Speed - 1.0) -gt 0.01) { Inject-SpeedKeeper $ws $cid $script:Speed | Out-Null }
                Inject-LiveSync $ws $cid | Out-Null
                $s = Eval-Js $ws $keepExpr $cid
            }
            # 记住真实视频页地址（浏览器意外重启后回到这里，而不是空白页）
            if ($s -and $s.u -and $s.u -notmatch '^about:') { $script:LastUrl = $s.u }
            Invoke-QuizTick $ws $cid   # 视频内答题助手（检测到才动作）
            if ($s -and $ticks % 6 -eq 0) { Log ("进度：{0}/{1}秒 暂停={2}" -f $s.t, $s.d, $s.p) }
        } catch {
            # 连接断开则重连整个页面；浏览器进程没了则自动重启
            try {
                $ws.Dispose()
                $script:CdpEvents = @()
                if (-not (Wait-Cdp 1)) {
                    Log "浏览器已关闭，自动重启并回到视频页..."
                    Start-Browser $script:LastUrl | Out-Null
                    Start-Sleep -Seconds 6
                }
                $p = Get-VideoTab
                if ($p) {
                    $ws = Cdp-Connect $p.webSocketDebuggerUrl
                    Invoke-Cdp $ws 'Runtime.enable' @{} | Out-Null
                    $cid = Find-VideoContext $ws
                    if ($null -ne $cid -and [math]::Abs($script:Speed - 1.0) -gt 0.01) { Inject-SpeedKeeper $ws $cid $script:Speed | Out-Null }
                    if ($null -ne $cid) { Inject-LiveSync $ws $cid | Out-Null }
                }
            } catch {}
        }
    }
}

# ---------- 完成度同步（补齐观看覆盖率，让平台判定完成）----------
# 原理：平台按心跳上报的观看位置(cp)累计覆盖率。挂播时若心跳上报不完整，
# 画面虽到结尾但服务端只记一部分。这里读取真实播放进度，批量补报心跳把
# 覆盖率补满，再刷新页面让完成度落地。仅处理当前已打开的课程视频页。
function Sync-Completion {
    if (-not (Wait-Cdp 2)) { Fail "浏览器未运行或调试端口未就绪"; return }
    $p = Get-VideoTab
    if (-not $p) { Fail "没有可用窗口，请先打开课程视频页并登录"; return }
    $ws = Cdp-Connect $p.webSocketDebuggerUrl
    Invoke-Cdp $ws 'Runtime.enable' @{} | Out-Null

    # 页面内脚本：自动发现参数 → 查进度 → 补报心跳 → 返回统计。
    # 所有平台参数从播放器实例和 localStorage 动态读取，不写死。
    $expr = @"
(async () => {
  const out = {ok:false};
  try {
    const host = document.querySelector('div.xtplayer');
    const p = host && host.__vue__ && host.__vue__.player;
    if (!p) { out.err = '当前页面未检测到已适配的播放器（完成度同步目前仅适配雨课堂系平台）；播放和倍速功能不受影响'; return out; }
    const o = p.options;
    const hb = p.heartBeat;
    const base = hb ? JSON.parse(JSON.stringify(hb.params)) : null;
    if (!base) { out.err = '未找到心跳上报参数'; return out; }

    const cid = o.cid || base.c;
    const uid = o.userId || base.u;
    const room = o.classroom_id || base.classroomid;
    const vid = o.id || base.v;
    const duration = Math.round((o.duration || (isNaN(p.video.duration)?0:p.video.duration)) || 0);
    if (!cid || !uid || !room || !vid || !duration) {
      out.err = '缺少进度参数（cid/uid/classroom/video/duration）';
      return out;
    }
    out.params = {cid, uid, room, vid, duration};

    const progressUrl = '/video-log/get_video_watch_progress/?cid=' + cid +
      '&user_id=' + uid + '&classroom_id=' + room +
      '&video_type=video&vtype=rate&video_id=' + vid;
    const readProgress = async () => {
      const r = await fetch(progressUrl, {credentials:'include'});
      const j = await r.json();
      return (j.data && j.data[vid]) || j[vid] || null;
    };

    let cur = await readProgress();
    if (!cur) { out.err = '读取观看进度失败'; return out; }
    out.before = {rate:cur.rate, last:Math.round(cur.last_point||0), completed:cur.completed};
    if (cur.completed) { out.ok = true; out.msg = '该视频已完成，无需同步'; return out; }

    // 目标倍速（用播放器当前设定，默认2）
    let target = (o.speed && o.speed.value) || 2;
    if (!(target > 0)) target = 2;
    const csrftoken = (document.cookie.match(/csrftoken=([^;]+)/) || [])[1] || '';
    const headers = {'Content-Type':'application/json', 'X-CSRFToken':csrftoken, 'xtbz':'ykt'};

    // 从服务端记录的观看位置继续，按合理间隔递增 cp 到结尾
    const startCp = Math.floor((cur.last_point || 0) + 1);
    const step = 6, batch = 200;
    let cp = startCp, sq = (base.sq || 0) + 1000, batches = 0, sent = 0;
    const tsBase = Date.now();
    const d = JSON.parse(JSON.stringify(base));
    while (cp <= duration && batches < 60) {
      const data = [];
      for (let i = 0; i < batch && cp <= duration; i++, cp += step, sq++) {
        const one = JSON.parse(JSON.stringify(d));
        one.et = 'heartbeat'; one.cp = cp; one.sp = target;
        one.ts = (tsBase + sq * 3000) + ''; one.sq = sq;
        data.push(one);
      }
      const resp = await fetch('/video-log/heartbeat/', {
        method:'POST', credentials:'include', headers,
        body: JSON.stringify({heart_data: data})
      });
      if (!resp.ok) { out.err = '心跳上报失败 HTTP ' + resp.status; return out; }
      sent += data.length; batches++;
      await new Promise(r => setTimeout(r, 200));
    }

    await new Promise(r => setTimeout(r, 1500));
    cur = await readProgress();
    out.after = {rate:cur.rate, last:Math.round(cur.last_point||0), completed:cur.completed};
    out.sent = sent; out.batches = batches;

    // 刷新页面，让前端完成度重新拉取并落地
    if (cur.completed || cur.rate > 0.98) {
      location.reload();
      out.ok = true;
      out.msg = '完成度已补齐，正在刷新页面';
    } else {
      out.ok = false;
      out.msg = '已补报但服务端未判定完成，可再运行一次';
    }
    return out;
  } catch (e) {
    out.err = e.message;
    return out;
  }
})()
"@
    $result = Eval-Js $ws $expr
    $ws.Dispose()

    if ($null -eq $result) { Fail "同步脚本无返回"; return }
    if ($result.err) { Fail $result.err; return }
    if ($result.msg -and -not $result.after) { Log $result.msg; return }
    Log ("补报 " + $result.sent + " 条心跳（" + $result.batches + " 批）")
    if ($result.before) {
        $b = $result.before
        $a = $result.after
        Log ("覆盖率：{0}% → {1}%  完成：{2} → {3}" -f [math]::Round(100*$b.rate,1), [math]::Round(100*$a.rate,1), $b.completed, $a.completed)
    }
    if ($result.msg) { Log $result.msg }
    if ($result.after -and $result.after.completed) { Log "✓ 该视频已完成" }
}

# ---------- 状态 ----------
function Show-Status {
    if (-not (Wait-Cdp 2)) { Fail "浏览器未运行或调试端口未就绪"; return }
    $tabs = Get-Json '/json/list'
    $pages = $tabs | Where-Object { $_.type -eq 'page' -and $_.url -match '^https?://' }
    if (-not $pages) { Write-Host "没有打开的网页"; return }
    $statusExpr = $script:FIND_JS + "return vs.map(v=>({t:Math.round(v.currentTime),d:Math.round(v.duration||0),paused:v.paused,ready:v.readyState}));})()"
    foreach ($t in $pages) {
        $ws = Cdp-Connect $t.webSocketDebuggerUrl
        Invoke-Cdp $ws 'Runtime.enable' @{} | Out-Null
        $meta = Eval-Js $ws "({title:document.title,url:location.href})"
        $ids = Get-ContextIds $ws
        $found = $false
        foreach ($cid in $ids) {
            $videos = @(Eval-Js $ws $statusExpr $cid)
            if ($null -ne $videos -and $videos.Count -gt 0) {
                if (-not $found) {
                    Write-Host ("  标题：" + $meta.title)
                    Write-Host ("  网址：" + $meta.url)
                    $found = $true
                }
                foreach ($v in $videos) {
                    $state = if ($v.paused) { "已暂停" } else { "播放中" }
                    $pct = if ($v.d -gt 0) { [math]::Round(100*$v.t/$v.d, 1) } else { 0 }
                    Write-Host ("  视频：{0}  进度 {1}/{2} 秒 ({3}%)  缓冲={4}" -f $state, $v.t, $v.d, $pct, $v.ready)
                }
            }
        }
        if (-not $found) { Write-Host ("  标题：" + $meta.title + "（未发现视频，可能未登录或未到播放页）") }
        $ws.Dispose()
    }
}

# ---------- 恢复窗口 ----------
function Raise-Window {
    $p = Get-VideoTab
    if (-not $p) { Fail "没有可用窗口"; return }
    Set-Window $p.id 'normal'
    $ws = Cdp-Connect $p.webSocketDebuggerUrl
    Invoke-Cdp $ws 'Page.bringToFront' @{} | Out-Null
    $ws.Dispose()
    Log "窗口已恢复到前台"
}

# ---------- 即时设置倍速 ----------
function Apply-Speed([double]$newSpeed, [bool]$restartWatch) {
    if ($newSpeed -le 0) { Fail "倍速必须大于 0"; return }
    $script:Speed = $newSpeed
    $sp = $newSpeed
    # 立即应用到当前播放的所有 frame
    $p = Get-VideoTab
    if ($p) {
        $ws = Cdp-Connect $p.webSocketDebuggerUrl
        Invoke-Cdp $ws 'Runtime.enable' @{} | Out-Null
        foreach ($cid in (Get-ContextIds $ws)) {
            if ([math]::Abs($sp - 1.0) -gt 0.01) {
                Inject-SpeedKeeper $ws $cid $sp | Out-Null
            } else {
                Eval-Js $ws ($script:FIND_JS + "vs.forEach(v=>{try{v.playbackRate=1;}catch(e){}});return vs.length;})()") $cid | Out-Null
            }
        }
        $ws.Dispose()
    }
    # 重启保活后台作业（隐藏窗口），让新倍速持续生效
    if ($restartWatch) {
        try { Get-Job -Name 'KaoKeWatch' -ErrorAction SilentlyContinue | Stop-Job -PassThru | Remove-Job -Force } catch {}
        Start-WatchJob
    }
    Log ("倍速已设为 " + $sp + "x" + $(if ($restartWatch) { "，保活已同步" } else { "" }))
}

# ---------- 停止 ----------
function Stop-All {
    # 停掉保活后台作业
    try { Get-Job -Name 'KaoKeWatch' -ErrorAction SilentlyContinue | Stop-Job -PassThru | Remove-Job -Force } catch {}
    # 停掉保活的独立进程（兼容 -Action watch 模式）
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match "-Action watch" -and $_.CommandLine -match [regex]::Escape($ProfileDir) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Unregister-ScheduledTask -TaskName "KaoKeBrowser_$Port","KaoKeWatch_$Port" -Confirm:$false -ErrorAction SilentlyContinue
    $procs = Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$ProfileDir*" }
    foreach ($pr in $procs) { Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue }
    Log "已停止后台播放并清理相关任务"
}

# ---------- 菜单 ----------
function Show-Menu {
    while ($true) {
        Write-Host ""
        Write-Host "==============================================" -ForegroundColor Cyan
        Write-Host "       网课视频后台播放助手  v1.3" -ForegroundColor Cyan
        Write-Host ("       当前倍速：" + $script:Speed + "x") -ForegroundColor Cyan
        Write-Host "==============================================" -ForegroundColor Cyan
        Write-Host "  1. 播放视频（在弹出的浏览器里登录并打开视频页，回车即可）"
        Write-Host "  2. 查看当前播放状态"
        Write-Host "  3. 设置倍速（如 2 / 4 / 8 / 16）"
        Write-Host "  4. 恢复窗口到前台（登录 / 手动查看）"
        Write-Host "  5. 停止后台播放"
        Write-Host "  6. 完成度同步（补齐观看覆盖率；目前仅适配雨课堂系平台，其他平台自动跳过）"
        Write-Host ("  7. 无头模式：" + $(if (Get-Headless) { "开（浏览器隐形，选7关闭）" } else { "关（选7开启，开启后浏览器完全不显示）" }))
        Write-Host "  0. 退出"
        Write-Host "----------------------------------------------"
        $c = Read-Host "  请选择"
        switch ($c) {
            '1' {
                Write-Host "  直接回车 = 播放当前浏览器里已打开的视频页（推荐：在弹出的浏览器里登录并打开视频）"
                $u = Read-Host "  视频链接（可留空）"
                $sp = Read-Host ("  倍速（直接回车用当前 " + $script:Speed + "x）")
                if ($sp -match '^\d+(\.\d+)?$' -and [double]$sp -gt 0) { $script:Speed = [double]$sp }
                if ($u -eq '') {
                    if (Start-Playback '') { Start-WatchJob }
                } elseif ($u -match '^https?://') {
                    if (Start-Playback $u) { Start-WatchJob }
                } else { Fail "链接格式不对：留空直接回车，或以 http:// / https:// 开头" }
            }
            '2' { Show-Status }
            '3' {
                Write-Host "  提示：倍速上限以各平台自身档位为准（常见 2~16），超档可能无效"
                $sp = Read-Host ("  输入新倍速（如 1.5 / 2 / 4 / 8），当前 " + $script:Speed + "x")
                if ($sp -match '^\d+(\.\d+)?$' -and [double]$sp -gt 0) {
                    Apply-Speed ([double]$sp) $true
                } else { Fail "请输入大于 0 的数字" }
            }
            '4' { Raise-Window }
            '5' { Stop-All }
            '6' {
                Write-Host "  说明：先打开要完成的视频页并登录，本操作会补齐观看覆盖率。"
                Sync-Completion
            }
            '7' {
                if (Get-Headless) {
                    Set-Headless $false
                    Write-Host "  无头模式已关闭。下次启动浏览器会显示窗口（需要登录/手动操作时用这个）。" -ForegroundColor Green
                } else {
                    Set-Headless $true
                    Write-Host "  无头模式已开启。" -ForegroundColor Green
                    Write-Host "  注意：实测部分平台的播放器在'启动即隐形'时不挂载（如雨课堂），" -ForegroundColor Yellow
                    Write-Host "  若播放不了/找不到播放器，选 7 关闭本模式。" -ForegroundColor Yellow
                }
            }
            '0' { return }
            default { Write-Host "  无效选择" -ForegroundColor Yellow }
        }
    }
}

# ---------- 入口 ----------
switch ($Action) {
    'launch' { Start-Browser $Url | Out-Null }
    'play'   { Start-Playback $Url | Out-Null }
    'status' { Show-Status }
    'raise'  { Raise-Window }
    'stop'   { Stop-All }
    'speed'  { Apply-Speed $Speed $true }
    'watch'  { Run-WatchLoop }
    'complete' { Sync-Completion }
    ''       { Show-Menu }
    default  { Fail ("未知动作：" + $Action) }
}
