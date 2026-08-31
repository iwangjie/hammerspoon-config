--- wifiCaptive.lua
--- Wi-Fi 断网后自动检测并认证强制门户（Captive Portal）。
---
--- 检测原理：直接向公司网关 http://10.10.10.1:8081/logout_info 发请求。
--- 已认证时返回 UserName:王杰，需要认证时则返回不同内容（无此字段）。
--- 本地局域网请求不会被网关在上级路由白名单，比 captive.apple.com 可靠。
---
--- 所有 HTTP 请求均走 hs.http（macOS 原生 URL Loading System），
--- 用 Cookie 请求头模拟浏览器会话，与网关兼容性最好。
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

-- 请求超时（秒）；hs.http 用 get 的最后一个参数 timeout
local PROBE_TIMEOUT = 8

local CNA_PATH = "/System/Library/CoreServices/Captive Network Assistant.app"
local USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"

-- ==================== 状态 ====================

local state = {
  checking = false,       -- 防止重入
  fastAttempts = 0,       -- 本次断网已做的密集探测次数
  autoAuthAttempts = 0,   -- 自动认证已尝试次数
  manualAttempts = 0,     -- 手动流程复查次数
  checkTimer = nil,       -- 探测定时器
  authRetryTimer = nil,   -- 认证失败后的重试定时器
  cnaApp = nil,           -- Captive Network Assistant
  cachedIp = "",          -- 缓存 IP/MAC，避免每次跑同步命令
  cachedMac = "",
}

-- 门户凭据
local okCreds, creds = pcall(dofile, hs.configdir .. "/private/captive.lua")
if not okCreds or type(creds) ~= "table" or not creds.portalBase or not creds.loginBody then
  creds = nil
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

-- 门户登录所需的完整请求头（Cookie 会话 + UA + 来源）
local function makeHeaders(referer)
  local headers = {
    ["User-Agent"] = USER_AGENT,
  }
  if creds and creds.loginCookie then
    headers["Cookie"] = creds.loginCookie
  end
  if referer then
    headers["Referer"] = referer
  end
  return headers
end

-- 异步 GET，callback(status, body)
local function asyncGet(url, callback)
  hs.http.asyncGet(url, makeHeaders(), function(status, body, headers)
    callback(status, body)
  end)
end

-- 异步 POST，callback(status, body)
local function asyncPost(url, extraHeaders, body, callback)
  local headers = makeHeaders(nil)
  for k, v in pairs(extraHeaders or {}) do
    headers[k] = v
  end
  hs.http.asyncPost(url, body, headers, function(status, body, respHeaders)
    callback(status, body)
  end)
end

-- 刷新 IP/MAC 缓存（SSID 变化时才调用）
local function refreshIfaceInfo()
  state.cachedIp = hs.execute("ipconfig getifaddr en0 2>/dev/null"):gsub("%s+", "")
  state.cachedMac = hs.execute("ifconfig en0 2>/dev/null | awk '/ether/{print $2}'"):gsub(":", ""):gsub("%s+", "")
end

local function getIfaceInfo()
  if state.cachedIp == "" then
    refreshIfaceInfo()
  end
  return state.cachedIp, state.cachedMac
end

local function getProbeUrl()
  if creds and creds.portalBase then
    return creds.portalBase .. "/logout_info"
  end
  return "http://captive.apple.com/hotspot-detect.html"
end

-- ==================== 探测 ====================

-- 探测网络状态：返回 "online" / "captive" / "offline"
-- 有 portalBase 时用 /logout_info（带 Cookie/UA，识别会话），返回 UserName: 即已认证
-- 否则用 captive.apple.com（返回 Success 即在线）
local function probeOnce(callback)
  local probeUrl = getProbeUrl()

  if creds and creds.portalBase and probeUrl:find(creds.portalBase, 1, true) then
    asyncGet(probeUrl, function(status, body)
      if status == 200 and body and body:find("UserName:", 1, true) then
        callback("online")
      elseif status == 200 then
        callback("captive")
      else
        callback("offline")
      end
    end)
    return
  end

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

-- 带一次重试的探测：瞬态失败时自动重试，避免误判
local function probeNetwork(callback)
  probeOnce(function(result)
    if result ~= "offline" then
      callback(result)
      return
    end
    probeOnce(callback)
  end)
end

-- ==================== 手动登录窗口 ====================

local function openCaptiveAssistant()
  if state.cnaApp and state.cnaApp:isRunning() then
    log("Captive Network Assistant already running")
    return
  end
  log("Opening Captive Network Assistant")
  hs.application.open(CNA_PATH, 0, true)
  state.cnaApp = hs.application.get("Captive Network Assistant")
end

local function closeCaptiveAssistant()
  local app = state.cnaApp or hs.application.get("Captive Network Assistant")
  if app and app:isRunning() then
    log("Closing Captive Network Assistant")
    app:kill()
  end
  state.cnaApp = nil
end

-- 打开登录窗口后周期复查，直到 online 或超限
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
      recheckUntilOnline("manual fallback (no IP)")
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

  -- 第一步：GET 门户页
  asyncGet(portalURL, function(status, body)
    if status ~= 200 then log("Portal GET status=" .. tostring(status)) end

    -- 第二步：POST 登录表单
    local postBody = creds.loginBody
    asyncPost(creds.portalBase .. "/login.html", {
      ["Content-Type"] = "application/x-www-form-urlencoded",
      ["Origin"] = creds.portalBase,
      ["Referer"] = portalURL,
    }, postBody, function(postStatus, postBody)
      if postStatus ~= 302 and postStatus ~= 200 then
        log("Login POST status=" .. tostring(postStatus))
      end
      -- 第三步：等网关放行后复查
      hs.timer.doAfter(AUTH_SETTLE_DELAY, function()
        probeNetwork(autoAuthDone)
      end)
    end)
  end)
end

-- ==================== 认证入口 ====================

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

-- 慢速轮询定时器（密集阶段未恢复时降级）
local function createSlowPollTimer()
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
        if state.checkTimer then
          state.checkTimer:stop()
          state.checkTimer = nil
        end
        state.checking = false
        return
      end

      -- offline：密集阶段结束后转慢速轮询
      if state.fastAttempts >= FAST_MAX_ATTEMPTS then
        if state.checkTimer then
          state.checkTimer:stop()
          state.checkTimer = nil
        end
        createSlowPollTimer()
      end

      state.checking = false
    end)
  end)
end

-- ==================== 对外接口 ====================

function M.checkNow()
  if not isWorkWifi(hs.wifi.currentNetwork()) then
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

function M.onNetworkMaybeChanged()
  if not isWorkWifi(hs.wifi.currentNetwork()) then return end
  -- SSID 变化说明网卡可能重新分配了 IP，刷新缓存
  refreshIfaceInfo()
  hs.timer.doAfter(2, function()
    if state.checkTimer or state.authRetryTimer or state.checking then return end
    startCheck()
  end)
end

M.CNA_PATH = CNA_PATH

-- ==================== 事件接线 ====================

wifiCaptiveWatcher = hs.wifi.watcher.new(function(_, message, interface)
  if message == "SSIDChange" then
    M.onNetworkMaybeChanged()
  end
end)
wifiCaptiveWatcher:watchingFor({ "SSIDChange" })
wifiCaptiveWatcher:start()

sleepCaptiveWatcher = hs.caffeinate.watcher.new(function(event)
  if event == hs.caffeinate.watcher.systemDidWake then
    M.onNetworkMaybeChanged()
  end
end)
sleepCaptiveWatcher:start()

-- 兜底：每 1 分钟检查一次，覆盖退出认证但 SSID 未变的情况
backgroundCaptiveTimer = hs.timer.doEvery(60, function()
  if state.checkTimer or state.authRetryTimer or state.checking then return end
  if not isWorkWifi(hs.wifi.currentNetwork()) then return end
  probeNetwork(function(result)
    if result == "captive" then
      onCaptiveDetected("background check")
    end
  end)
end)

log("Loaded" .. (creds and " (portal credentials configured)" or " (no portal credentials)"))

return M