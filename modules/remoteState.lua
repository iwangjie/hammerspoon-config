--- remoteState.lua
--- 把 note.ms 上的 JSON 当作期望状态，周期性观察本机并调和（类似 k8s reconcile）。
---
--- 期望状态示例（写在 command URL 的纯文本里）：
--- {
---     "app": { "uuremote": "running" },
---     "sys": { "brightness": 20 }
--- }
---
--- 未出现的字段不管理。只把本机往期望拉，不会把本机状态写回 command 页。
--- 实际改动会追加一行到 log URL。

local M = {}

local CURL = "/usr/bin/curl"
-- note.ms：curl UA 返回纯文本，浏览器 UA 返回整页 HTML。
local USER_AGENT = "curl/8.7.1"
local MAX_LOG_LINES = 80
local PARSE_ERROR_COOLDOWN = 120

local COMMAND_URL = remoteStateUrl or "https://note.ms/13373381619"
local LOG_URL = remoteStateLogUrl or "https://note.ms/13373381619log"
local INTERVAL = tonumber(remoteStateInterval) or 20

local state = {
  busy = false,
  timer = nil,
  pendingTask = nil,
  lastParseErrorAt = 0,
}

local function log(text)
  print("[remoteState] " .. text)
end

local function notify(text)
  hs.notify.new({ title = "HS Robot", informativeText = text }):send()
end

local function curlToFile(args, callback)
  local tmpfile = os.tmpname() .. ".txt"
  local fullArgs = {}
  for _, a in ipairs(args) do
    table.insert(fullArgs, a)
  end
  table.insert(fullArgs, "-o")
  table.insert(fullArgs, tmpfile)

  local task = hs.task.new(CURL, function(exitCode)
    state.pendingTask = nil
    local content = ""
    local f = io.open(tmpfile, "rb")
    if f then
      content = f:read("*a") or ""
      f:close()
    end
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

-- curl 默认 UA 会拿到 note.ms 的纯文本；浏览器 UA 会拿到整页 HTML。
local function httpGet(url, callback)
  curlToFile({
    "-sS", "--max-time", "15",
    "-A", USER_AGENT,
    url,
  }, callback)
end

local function httpPostText(url, text, callback)
  curlToFile({
    "-sS", "--max-time", "15",
    "-A", USER_AGENT,
    "-H", "Referer: " .. url,
    "-H", "Content-Type: application/x-www-form-urlencoded",
    "-X", "POST",
    "--data-urlencode", "t=" .. (text or ""),
    url,
  }, callback)
end

local function looksLikeHtml(text)
  if not text or text == "" then return false end
  local head = text:sub(1, 200):lower()
  return head:find("<!doctype", 1, true) or head:find("<html", 1, true)
end

local function unescapeHtml(s)
  s = s:gsub("&quot;", '"'):gsub("&#34;", '"')
  s = s:gsub("&apos;", "'"):gsub("&#39;", "'")
  s = s:gsub("&lt;", "<"):gsub("&gt;", ">")
  s = s:gsub("&amp;", "&")
  return s
end

-- GET 可能是纯文本，也可能是带 textarea 的 HTML。
local function noteBody(raw)
  if not raw then return "" end
  local text = raw
  if looksLikeHtml(raw) then
    local inner = raw:match('<textarea class="content">(.-)</textarea>')
      or raw:match("<textarea[^>]*>(.-)</textarea>")
    text = unescapeHtml(inner or "")
  end
  return (text:gsub("^\239\187\191", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function decodeDesired(raw)
  local text = noteBody(raw)
  if text == "" then return nil, "empty" end
  local jsonText = text:match("%b{}")
  if not jsonText then return nil, "no json object" end
  local ok, data = pcall(hs.json.decode, jsonText)
  if not ok or type(data) ~= "table" then
    return nil, "invalid json"
  end
  return data, nil
end

local function isUURemoteRunning()
  local app = hs.application.get("com.netease.uuremote")
  if app and app:isRunning() then
    return true
  end
  local out = hs.execute("/usr/bin/pgrep -x UURemote") or ""
  return out:match("%d") ~= nil
end

local function setUURemote(desired)
  if desired == "running" then
    if isUURemoteRunning() then return false, "already running" end
    -- kill 路径会 bootout agent；这里重新装上，避免只打开了窗口、后台服务没起来。
    hs.execute("launchctl bootstrap gui/$(id -u) /Library/LaunchAgents/com.netease.uuremote.agent.plist >/dev/null 2>&1", true)
    if scheduledApps and scheduledApps.openUURemote then
      scheduledApps.openUURemote()
    else
      hs.application.launchOrFocus("UURemote")
    end
    return true, "started"
  end

  if desired == "stopped" then
    if not isUURemoteRunning() then return false, "already stopped" end
    if scheduledApps and scheduledApps.killUURemote then
      scheduledApps.killUURemote()
    else
      hs.execute("launchctl bootout gui/$(id -u) com.netease.uuremote.agent >/dev/null 2>&1", true)
      hs.execute("pkill -f /Applications/UURemote.app", true)
    end
    return true, "stopped"
  end

  return false, "unsupported value " .. tostring(desired)
end

local function currentBrightness()
  local n = hs.brightness.get()
  if type(n) ~= "number" then return nil end
  return math.floor(n + 0.5)
end

local function setBrightness(desired)
  local n = tonumber(desired)
  if n == nil then return false, "invalid brightness" end
  n = math.floor(n + 0.5)
  if n < 0 then n = 0 end
  if n > 100 then n = 100 end
  local cur = currentBrightness()
  if cur and math.abs(cur - n) < 1 then
    return false, "already " .. tostring(cur)
  end
  local ok = hs.brightness.set(n)
  if not ok then
    return false, "set failed"
  end
  return true, (cur and (tostring(cur) .. " -> " .. tostring(n)) or ("set " .. tostring(n)))
end

local function trimLog(text)
  text = noteBody(text):gsub("\r\n", "\n")
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then table.insert(lines, line) end
  end
  if #lines > MAX_LOG_LINES then
    local keep = {}
    for i = #lines - MAX_LOG_LINES + 1, #lines do
      table.insert(keep, lines[i])
    end
    lines = keep
  end
  return table.concat(lines, "\n")
end

local function appendLog(entries, callback)
  if not entries or #entries == 0 then
    if callback then callback(true) end
    return
  end

  local stamp = os.date("%Y-%m-%d %H:%M:%S")
  local newLines = {}
  for _, entry in ipairs(entries) do
    table.insert(newLines, stamp .. " " .. entry)
  end
  local added = table.concat(newLines, "\n")

  httpGet(LOG_URL, function(exitCode, body)
    if exitCode ~= 0 then
      log("log get failed exit=" .. tostring(exitCode))
      if callback then callback(false) end
      return
    end
    local current = trimLog(body)
    local nextText = current == "" and added or (current .. "\n" .. added)
    httpPostText(LOG_URL, nextText, function(postExit)
      if postExit ~= 0 then
        log("log post failed exit=" .. tostring(postExit))
        if callback then callback(false) end
        return
      end
      if callback then callback(true) end
    end)
  end)
end

local function reconcile(desired)
  local changes = {}

  local appSpec = desired.app
  if type(appSpec) == "table" then
    local uu = appSpec.uuremote
    if uu ~= nil then
      if uu ~= "running" and uu ~= "stopped" then
        table.insert(changes, "uuremote: 忽略非法值 " .. tostring(uu))
      else
        local applied, detail = setUURemote(uu)
        if applied then
          table.insert(changes, "uuremote: " .. detail)
          notify("UU 远程桌面已" .. (uu == "running" and "启动" or "关闭"))
        else
          log("uuremote noop: " .. tostring(detail))
        end
      end
    end
  end

  local sysSpec = desired.sys
  if type(sysSpec) == "table" then
    if sysSpec.brightness ~= nil then
      local applied, detail = setBrightness(sysSpec.brightness)
      if applied then
        table.insert(changes, "brightness: " .. detail)
        notify("亮度已设为 " .. tostring(math.floor(tonumber(sysSpec.brightness) + 0.5)))
      else
        log("brightness noop: " .. tostring(detail))
      end
    end
  end

  return changes
end

local function tick()
  if state.busy then return end
  state.busy = true

  httpGet(COMMAND_URL, function(exitCode, body)
    if exitCode ~= 0 then
      log("desired get failed exit=" .. tostring(exitCode))
      state.busy = false
      return
    end

    local desired, err = decodeDesired(body)
    if not desired then
      local now = hs.timer.secondsSinceEpoch()
      if err ~= "empty" and (now - state.lastParseErrorAt) > PARSE_ERROR_COOLDOWN then
        state.lastParseErrorAt = now
        log("desired parse failed: " .. tostring(err))
        appendLog({ "desired: 解析失败（" .. tostring(err) .. "），请写成 JSON" }, function()
          state.busy = false
        end)
        return
      end
      state.busy = false
      return
    end

    local changes = reconcile(desired)
    if #changes == 0 then
      state.busy = false
      return
    end

    for _, line in ipairs(changes) do
      log(line)
    end
    appendLog(changes, function()
      state.busy = false
    end)
  end)
end

function M.reconcileNow()
  tick()
end

function M.status()
  local uu = isUURemoteRunning() and "running" or "stopped"
  local brightness = currentBrightness()
  log("actual uuremote=" .. uu .. " brightness=" .. tostring(brightness))
  return { uuremote = uu, brightness = brightness }
end

state.timer = hs.timer.doEvery(INTERVAL, tick)
hs.timer.doAfter(3, tick)
log("Loaded, polling " .. COMMAND_URL .. " every " .. tostring(INTERVAL) .. "s")

return M
