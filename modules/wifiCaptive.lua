--- wifiCaptive.lua
--- Wi-Fi 断网后自动检测并认证强制门户（Captive Portal）。
---
--- 检测原理：直接向公司网关 http://10.10.10.1:8081/logout_info 发请求。
--- 已认证时返回 UserName:王杰，需要认证时则返回不同内容（无此字段）。
--- 本地局域网请求不会被网关在上级路由白名单，比 captive.apple.com 可靠。
---
--- 检测到需要认证后，自动复刻浏览器抓包流程完成认证：
---   1. GET /?userip=...&usermac=...&info=
---   2. POST /login.html 提交登录表单
---
--- 自动认证 5 次失败后，退回打开系统 Captive Network Assistant 窗口。
--- 仅对 config.lua 中 workWifis 里的公司 Wi-Fi 生效。

local M = {}

-- ==================== 可调参数 ====================

-- 断网后的探测节奏（秒）：先密集探测，超限后进入慢速轮询
local FAST_INTERVAL = 5
local FAST_MAX_ATTEMPTS = 6
local SLOW_INTERVAL = 60

-- 自动认证：最多尝试次数与两次尝试间隔（秒）
local AUTO_AUTH_MAX_ATTEMPTS = 5
local AUTO_AUTH_RETRY_INTERVAL = 10
-- POST 成功后等待网关放行的秒数
local AUTH_SETTLE_DELAY = 3

-- 退回手动流程（打开登录窗口）后：复查间隔与次数
local MANUAL_RETRY_INTERVAL = 15
local MANUAL_MAX_ATTEMPTS = 12

-- 请求超时（秒）
local PROBE_TIMEOUT = 8

-- 检测地址：网关的 logout_info 接口，在线时返回 UserName:王杰
-- 这是本地局域网请求，不会被门户在上级路由白名单
local CNA_PATH = "/System/Library/CoreServices/Captive Network Assistant.app"
local CURL = "/usr/bin/curl"
local USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"

-- ==================== 状态 ====================

local state = {
  checking = false,       -- 正在探测/认证中，防止重入
  fastAttempts = 0,       -- 本次断网已做的密集探测次数
  autoAuthAttempts = 0,   -- 自动认证已尝试次数
  manualAttempts = 0,     -- 手动流程（登录窗口）复查次数
  checkTimer = nil,       -- 探测定时器
  authRetryTimer = nil,   -- 认证失败后的重试定时器
  pendingTask = nil,      -- 在飞的 curl 任务，防止被 GC
  cnaApp = nil,           -- Captive Network Assistant 的 hs.application 对象
}

-- 门户凭据（portalBase / loginBody / loginCookie），可选
local okCreds, creds = pcall(dofile, hs.configdir .. "/private/captive.lua")
if not okCreds or type(creds) ~= "table" or not creds.portalBase or not creds.loginBody then
  creds = nil
end

-- 探测地址：优先用网关 logout_info，其次 captive.apple.com
local function getProbeUrl()
  if creds and creds.portalBase then
    return creds.portalBase .. "/logout_info"
  end
  return "http://captive.apple.com/hotspot-detect.html"
end

-- ==================== 工具函数 ====================

local function isWorkWifi(networkName)
  if not networkName then return false end
  if workWifi and networkName == workWifi then return true end
  for _, wifiName in ipairs(workWifis or {}) do
    if networkName == wifiName then return true end
  end
  return false
end

local function currentWifi()
  return hs.wifi.currentNetwork()
end

local function notify(text)
  hs.notify.new({ title = "HS Robot", informativeText = text }):send()
end

local function log(text)
  print("[wifiCaptive] " .. text)
end

local function stopAuthRetryTimer()
  if state.authRetryTimer then
    state.authRetryTimer:stop()
    state.authRetryTimer = nil
  end
end

-- 异步跑一条 curl，结束后 callback(exitCode, stdout)
local function curlTask(args, callback)
  local task = hs.task.new(CURL, function(exitCode, stdout, stderr)
    state.pendingTask = nil
    if callback then callback(exitCode, stdout or "") end
  end, args)
  if not task then return nil end
  state.pendingTask = task
  task:start()
  return task
end

-- 取当前 Wi-Fi 网卡的 IP 和 MAC（mac 形如 c470abe676d7，与门户要求一致）
local function getIfaceInfo()
  local ip = hs.execute("ipconfig getifaddr en0 2>/dev/null"):gsub("%s+", "")
  local mac = hs.execute("ifconfig en0 2>/dev/null | awk '/ether/{print $2}'"):gsub(":", ""):gsub("%s+", "")
  return ip, mac
end

-- 探测网络状态：返回 "online" / "captive" / "offline"
-- 有 portalBase 时用 curl 请求 /logout_info（带正确 Cookie/UA，避免网关拒接）
-- 否则用 captive.apple.com（hs.http 即可，不需要特殊 headers）
local function probeNetwork(callback)
  local probeUrl = getProbeUrl()

  -- 有 portalBase：用 curl 走 /logout_info，带抓包确认正确的 headers
  if creds and creds.portalBase and probeUrl:find(creds.portalBase, 1, true) then
    curlTask({
      "--max-time", tostring(PROBE_TIMEOUT), "--insecure", "-s",
      "-b", creds.loginCookie,
      "-A", USER_AGENT,
      probeUrl
    }, function(exitCode, stdout)
      if exitCode ~= 0 then
        callback("offline")
        return
      end
      if stdout:find("UserName:", 1, true) then
        callback("online")
      else
        callback("captive")
      end
    end)
    return
  end

  -- 无 portalBase：用 captive.apple.com（兜底）
  hs.http.asyncGet(probeUrl, nil, function(status, body, headers)
    if status == 200 and body and body:find("Success", 1, true) then
      callback("online")
    elseif status == 200 then
      callback("captive")
    else
      callback("offline")
    end
  end)
end

-- 打开系统的 Captive Network Assistant（Wi-Fi 登录窗口）
local function openCaptiveAssistant()
  if state.cnaApp and state.cnaApp:isRunning() then
    log("Captive Network Assistant already running")
    return
  end
  log("Opening Captive Network Assistant")
  hs.application.open(CNA_PATH, 0, true)
  state.cnaApp = hs.application.get("Captive Network Assistant")
end

-- 关闭 Captive Network Assistant
local function closeCaptiveAssistant()
  local app = state.cnaApp or hs.application.get("Captive Network Assistant")
  if app and app:isRunning() then
    log("Closing Captive Network Assistant")
    app:kill()
  end
  state.cnaApp = nil
end

-- 打开登录窗口后周期复查：认证成功（online）即收尾；复查超限则提醒手动处理
local function recheckUntilOnline(tag)
  probeNetwork(function(result)
    if result == "online" then
      log(tag .. ": network online")
      notify("Wi-Fi 认证完成，网络已恢复")
      closeCaptiveAssistant()
      state.checking = false
      return
    end

    state.manualAttempts = state.manualAttempts + 1
    if state.manualAttempts >= MANUAL_MAX_ATTEMPTS then
      log(tag .. ": manual recheck exhausted")
      notify("Wi-Fi 认证仍未完成，请手动登录")
      state.checking = false
      return
    end

    stopAuthRetryTimer()
    state.authRetryTimer = hs.timer.doAfter(MANUAL_RETRY_INTERVAL, function()
      state.authRetryTimer = nil
      recheckUntilOnline(tag)
    end)
  end)
end

-- ==================== 自动认证（锐捷 ePortal） ====================

local function autoAuthDone(result)
  if result == "online" then
    log("Auto auth success, network is online")
    notify("Wi-Fi 自动认证成功，网络已恢复")
    closeCaptiveAssistant()
    state.checking = false
    return
  end

  if result == "offline" then
    log("Auto auth sent but network still offline")
  else
    log("Auto auth sent but still captive")
  end

  state.autoAuthAttempts = state.autoAuthAttempts + 1
  if state.autoAuthAttempts >= AUTO_AUTH_MAX_ATTEMPTS then
    log("Auto auth attempts exhausted, falling back to manual login window")
    notify("Wi-Fi 自动认证未成功，请手动登录")
    openCaptiveAssistant()
    recheckUntilOnline("manual fallback")
    return
  end

  log("Retrying auto auth in " .. AUTO_AUTH_RETRY_INTERVAL .. "s ("
    .. state.autoAuthAttempts .. "/" .. AUTO_AUTH_MAX_ATTEMPTS .. ")")
  stopAuthRetryTimer()
  state.authRetryTimer = hs.timer.doAfter(AUTO_AUTH_RETRY_INTERVAL, function()
    state.authRetryTimer = nil
    M.attemptAutoAuth()
  end)
end

-- 一轮自动认证：GET 门户页（带 userip/usermac）→ POST 登录 → 等待放行 → 复查
function M.attemptAutoAuth()
  if not creds then
    state.checking = false
    return
  end

  local ip, mac = getIfaceInfo()
  if ip == "" then
    log("No local IP yet, retry later")
    state.autoAuthAttempts = state.autoAuthAttempts + 1
    if state.autoAuthAttempts >= AUTO_AUTH_MAX_ATTEMPTS then
      notify("Wi-Fi 自动认证未成功，请手动登录")
      openCaptiveAssistant()
      recheckUntilOnline("manual fallback")
      return
    end
    stopAuthRetryTimer()
    state.authRetryTimer = hs.timer.doAfter(AUTO_AUTH_RETRY_INTERVAL, function()
      state.authRetryTimer = nil
      M.attemptAutoAuth()
    end)
    return
  end
  log("Auto auth attempt " .. (state.autoAuthAttempts + 1) .. "/" .. AUTO_AUTH_MAX_ATTEMPTS
    .. " (ip=" .. ip .. " mac=" .. mac .. ")")

  local portalURL = creds.portalBase .. "/?userip=" .. ip .. "&usermac=" .. mac .. "&info="

  -- 第一步：GET 门户页，等它返回后再 POST（复刻浏览器抓包顺序）
  local getUrl = { "--max-time", tostring(PROBE_TIMEOUT), "--insecure", "-s",
    "-b", creds.loginCookie,
    "-A", USER_AGENT,
    portalURL }
  if not curlTask(getUrl, function(exitCode)
    if exitCode ~= 0 then log("Portal GET failed, exit=" .. exitCode) end

    -- 第二步：POST 登录表单
    local postUrl = { "--max-time", tostring(PROBE_TIMEOUT), "--insecure", "-s",
      "-X", "POST", creds.portalBase .. "/login.html",
      "-H", "Content-Type: application/x-www-form-urlencoded",
      "-H", "Origin: " .. creds.portalBase,
      "-H", "Referer: " .. portalURL,
      "-b", creds.loginCookie,
      "-A", USER_AGENT,
      "--data-raw", creds.loginBody,
      creds.portalBase .. "/login.html" }
    if not curlTask(postUrl, function(postExit)
      if postExit ~= 0 then log("Login POST failed, exit=" .. postExit) end
      -- 第三步：等网关放行后复查
      hs.timer.doAfter(AUTH_SETTLE_DELAY, function()
        probeNetwork(autoAuthDone)
      end)
    end) then
      log("Failed to start POST task")
      state.checking = false
    end
  end) then
    log("Failed to start GET task")
    state.checking = false
  end
end

-- ==================== 认证入口 ====================

-- 探测到 captive 后的入口：有凭据走自动认证，没有则走手动登录窗口流程
local function onCaptiveDetected(source)
  log("Captive portal detected (" .. source .. ")")
  stopAuthRetryTimer()
  state.checking = true
  state.autoAuthAttempts = 0
  state.manualAttempts = 0

  if creds then
    M.attemptAutoAuth()
  else
    log("No portal credentials configured, opening login window")
    notify("Wi-Fi 需要认证，已打开登录窗口")
    openCaptiveAssistant()
    recheckUntilOnline("manual")
  end
end

-- ==================== 断网检测 ====================

local function startCheck()
  if state.checkTimer then return end
  log("Starting connectivity check")

  state.checking = false
  state.fastAttempts = 0
  state.autoAuthAttempts = 0
  state.manualAttempts = 0

  state.checkTimer = hs.timer.doEvery(FAST_INTERVAL, function()
    if state.checking then return end
    state.checking = true

    probeNetwork(function(result)
      state.fastAttempts = state.fastAttempts + 1

      if result == "captive" then
        if state.checkTimer then
          state.checkTimer:stop()
          state.checkTimer = nil
        end
        state.checking = false
        onCaptiveDetected("fast poll")
        return
      end

      if result == "online" then
        log("Network recovered")
        state.checkTimer:stop()
        state.checkTimer = nil
        state.checking = false
        return
      end

      -- offline：继续探测。密集阶段结束后转慢速轮询
      if state.fastAttempts >= FAST_MAX_ATTEMPTS then
        state.checkTimer:stop()
        state.checkTimer = nil
        state.checkTimer = hs.timer.doEvery(SLOW_INTERVAL, function()
          if state.checking then return end
          state.checking = true
          probeNetwork(function(r)
            if r == "captive" then
              if state.checkTimer then
                state.checkTimer:stop()
                state.checkTimer = nil
              end
              state.checking = false
              onCaptiveDetected("slow poll")
              return
            end
            if r == "online" then
              log("Network recovered (slow poll)")
              if state.checkTimer then
                state.checkTimer:stop()
                state.checkTimer = nil
              end
            end
            state.checking = false
          end)
        end)
      end

      state.checking = false
    end)
  end)
end

local function stopCheck()
  if state.checkTimer then
    state.checkTimer:stop()
    state.checkTimer = nil
  end
  stopAuthRetryTimer()
  state.checking = false
  state.fastAttempts = 0
end

-- ==================== 对外接口 ====================

--- 手动触发一次检测
function M.checkNow()
  if not isWorkWifi(currentWifi()) then
    log("Not on work Wi-Fi, skip manual check")
    return
  end
  probeNetwork(function(result)
    log("Manual check: " .. result)
    if result == "captive" then
      onCaptiveDetected("manual check")
    elseif result == "online" then
      notify("网络正常")
    else
      notify("网络未就绪")
    end
  end)
end

--- 供外部（如 wifi.lua 的 SSIDChange 回调）调用
function M.onNetworkMaybeChanged()
  if not isWorkWifi(currentWifi()) then return end
  hs.timer.doAfter(2, function()
    if state.checkTimer or state.authRetryTimer or state.checking then return end
    startCheck()
  end)
end

M.CNA_PATH = CNA_PATH

-- ==================== 事件接线 ====================

-- Wi-Fi SSID 变化（断开重连、切换网络）时触发检测
wifiCaptiveWatcher = hs.wifi.watcher.new(function(_, message, interface)
  if message == "SSIDChange" then
    M.onNetworkMaybeChanged()
  end
end)
wifiCaptiveWatcher:watchingFor({ "SSIDChange" })
wifiCaptiveWatcher:start()

-- 系统休眠唤醒后也检查一次
sleepCaptiveWatcher = hs.caffeinate.watcher.new(function(event)
  if event == hs.caffeinate.watcher.systemDidWake then
    M.onNetworkMaybeChanged()
  end
end)
sleepCaptiveWatcher:start()

-- 兜底：每 2 分钟检查一次，覆盖退出认证但 SSID 未变的情况
-- 这是最关键的检测路径：用户退出认证后 Wi-Fi 不会断，SSID 不会变，
-- 只有兜底定时器能抓住这种场景。
backgroundCaptiveTimer = hs.timer.doEvery(120, function()
  if state.checkTimer or state.authRetryTimer or state.checking then return end
  if not isWorkWifi(currentWifi()) then return end
  probeNetwork(function(result)
    if result == "captive" then
      onCaptiveDetected("background check")
    end
  end)
end)

log("Loaded" .. (creds and " (portal credentials configured)" or " (no portal credentials)"))

return M