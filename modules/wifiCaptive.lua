--- wifiCaptive.lua
--- Wi-Fi 断网后自动检测并认证强制门户（Captive Portal）。
---
--- 检测原理：直接向公司网关 http://10.10.10.1:8081/logout_info 发请求。
--- 已认证时返回 UserName:王杰，需要认证时则返回不同内容（无此字段）。
---
--- 注意：网关返回 GBK 编码，hs.http 和 hs.task 的 stdout 捕获都会在
--- 编码转换时丢掉内容。因此所有 HTTP 请求都通过 hs.task + curl 写入
--- 临时文件，再用 io.open("rb") 读取原始字节，绕过编码层。

local M = {}

-- ==================== 可调参数 ====================

local FAST_INTERVAL = 5
local FAST_MAX_ATTEMPTS = 6
local SLOW_INTERVAL = 60

local AUTO_AUTH_MAX_ATTEMPTS = 5
local AUTO_AUTH_RETRY_INTERVAL = 10
local AUTH_SETTLE_DELAY = 3

local MANUAL_RETRY_INTERVAL = 15
local MANUAL_MAX_ATTEMPTS = 12

local PROBE_TIMEOUT = 8

local CNA_PATH = "/System/Library/CoreServices/Captive Network Assistant.app"
local CURL = "/usr/bin/curl"
local USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"

-- ==================== 状态 ====================

local state = {
  checking = false,
  fastAttempts = 0,
  autoAuthAttempts = 0,
  manualAttempts = 0,
  checkTimer = nil,
  authRetryTimer = nil,
  pendingTask = nil,
  cnaApp = nil,
  cachedIp = "",
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

-- 用 hs.task 跑 curl，将输出写入临时文件，然后回调中读取原始字节。
-- 这是唯一绕过 GBK 编码问题的方式：io.open("rb") 读原始字节，string.find 匹配 ASCII "UserName:"
local function curlWriteToFile(args, callback)
  -- 先将 args 整理成 curl 参数字符串
  local tmpfile = os.tmpname() .. ".txt"
  local fullArgs = {}
  for _, a in ipairs(args) do
    table.insert(fullArgs, a)
  end
  table.insert(fullArgs, "-o")
  table.insert(fullArgs, tmpfile)

  local task = hs.task.new(CURL, function(exitCode, stdout, stderr)
    state.pendingTask = nil
    -- 从临时文件读取原始字节
    local content = ""
    local f = io.open(tmpfile, "rb")
    if f then
      content = f:read("*a")
      f:close()
    end
    -- 清理
    pcall(os.remove, tmpfile)
    if callback then callback(exitCode, content) end
  end, fullArgs)

  if not task then
    log("Failed to create hs.task")
    pcall(os.remove, tmpfile)
    if callback then callback(-1, "") end
    return nil
  end
  state.pendingTask = task
  task:start()
  return task
end

-- 刷新 IP/MAC 缓存
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

local function httpGet(url, callback)
  curlWriteToFile({
    "--max-time", tostring(PROBE_TIMEOUT), "--insecure", "-s",
    "-H", "Cookie: " .. creds.loginCookie,
    "-A", USER_AGENT,
    url
  }, callback)
end

local function httpPost(url, data, callback)
  curlWriteToFile({
    "--max-time", tostring(PROBE_TIMEOUT), "--insecure", "-s",
    "-X", "POST",
    "-H", "Content-Type: application/x-www-form-urlencoded",
    "-H", "Origin: " .. creds.portalBase,
    "-H", "Cookie: " .. creds.loginCookie,
    "-A", USER_AGENT,
    "--data-raw", data,
    url
  }, callback)
end

-- ==================== 探测 ====================

local function probeOnce(callback)
  local probeUrl = getProbeUrl()

  if creds and creds.portalBase and probeUrl:find(creds.portalBase, 1, true) then
    httpGet(probeUrl, function(exitCode, body)
      log("probe exit=" .. tostring(exitCode) .. " bodyLen=" .. tostring(#body)
        .. " hasUserName=" .. tostring(body:find("UserName:", 1, true) and true or false))
      -- curl exit 码：0 成功；52 = CURLE_GOT_NOTHING（连接成功但响应为空）
      -- 对锐捷 ePortal，未认证时网关对 logout_info 就返回空响应（exit=52）。
      -- 因此只要请求能到达网关（连接层成功），响应里没有 UserName: 就视为 captive。
      local connectionOk = (exitCode == 0) or (exitCode == 52)
      if connectionOk and body:find("UserName:", 1, true) then
        callback("online")
      elseif connectionOk then
        callback("captive")
      else
        -- 真正连不上：超时(28)、连接被拒(7)、无法解析(6)等 → offline
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
  httpGet(portalURL, function(exitCode, body)
    if exitCode ~= 0 then log("Portal GET exit=" .. exitCode) end

    -- 第二步：POST 登录表单
    httpPost(creds.portalBase .. "/login.html", creds.loginBody, function(postExit, postBody)
      if postExit ~= 0 then log("Login POST exit=" .. postExit) end
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