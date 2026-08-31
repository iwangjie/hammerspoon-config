--- remoteState.lua
--- 把 GitHub 私有仓库里的 desired.json 当作期望状态，周期性观察本机并调和。
---
--- 期望状态示例：
--- {
---     "app": { "uuremote": "running" },
---     "sys": { "brightness": 20, "caffeinate": "running" }
--- }
---
--- 未出现的字段不管理。只把本机往期望拉，不会把本机状态写回 desired.json。
--- 实际改动会追加一行到同一个仓库的 log.md。

local M = {}

local CURL = "/usr/bin/curl"
local GH = remoteStateGh or "/opt/homebrew/bin/gh"
local OWNER = remoteStateOwner or "iwangjie"
local REPO = remoteStateRepo or "mac-remote-state"
local DESIRED_PATH = remoteStateDesiredPath or "desired.json"
local LOG_PATH = remoteStateLogPath or "log.md"
local INTERVAL = tonumber(remoteStateInterval) or 20
local API_VERSION = "2022-11-28"
local MAX_LOG_LINES = 80
local PARSE_ERROR_COOLDOWN = 120

local state = {
  busy = false,
  timer = nil,
  pendingTask = nil,
  token = nil,
  tokenWarned = false,
  desiredEtag = nil,
  desiredSha = nil,
  cachedDesired = nil,
  lastParseErrorAt = 0,
  caffeinateTask = nil,
  brightnessSettled = nil,
}

local function log(text)
  print("[remoteState] " .. text)
end

local function notify(text)
  hs.notify.new({ title = "HS Robot", informativeText = text }):send()
end

local function loadToken()
  if state.token and state.token ~= "" then
    return state.token
  end
  local ok, cfg = pcall(dofile, hs.configdir .. "/private/github.lua")
  if ok and type(cfg) == "table" and type(cfg.token) == "string" and cfg.token ~= "" then
    state.token = cfg.token
    return state.token
  end
  local out = hs.execute(string.format("%q auth token 2>/dev/null", GH)) or ""
  out = out:gsub("%s+", "")
  if out ~= "" then
    state.token = out
    return state.token
  end
  return nil
end

local function contentsUrl(path)
  return string.format(
    "https://api.github.com/repos/%s/%s/contents/%s",
    OWNER, REPO, path
  )
end

local function curlToFile(args, callback)
  local tmpfile = os.tmpname() .. ".txt"
  local hdrfile = os.tmpname() .. ".hdr"
  local fullArgs = { "-sS", "--max-time", "20", "-D", hdrfile }
  for _, a in ipairs(args) do
    table.insert(fullArgs, a)
  end
  table.insert(fullArgs, "-o")
  table.insert(fullArgs, tmpfile)

  local task = hs.task.new(CURL, function(exitCode)
    state.pendingTask = nil
    local body = ""
    local headers = ""
    local f = io.open(tmpfile, "rb")
    if f then
      body = f:read("*a") or ""
      f:close()
    end
    local h = io.open(hdrfile, "rb")
    if h then
      headers = h:read("*a") or ""
      h:close()
    end
    pcall(os.remove, tmpfile)
    pcall(os.remove, hdrfile)
    if callback then callback(exitCode, body, headers) end
  end, fullArgs)

  if not task then
    log("Failed to create hs.task")
    pcall(os.remove, tmpfile)
    pcall(os.remove, hdrfile)
    if callback then callback(-1, "", "") end
    return nil
  end
  state.pendingTask = task
  task:start()
  return task
end

local function parseHttp(headers)
  local status = 0
  local map = {}
  for line in (headers or ""):gmatch("[^\r\n]+") do
    local code = line:match("^HTTP/%S+%s+(%d+)")
    if code then
      status = tonumber(code) or 0
    else
      local k, v = line:match("^([^:]+):%s*(.*)$")
      if k then
        map[k:lower()] = v
      end
    end
  end
  return status, map
end

local function apiHeaders(extra)
  local token = loadToken()
  local headers = {
    "-H", "Accept: application/vnd.github+json",
    "-H", "X-GitHub-Api-Version: " .. API_VERSION,
    "-H", "User-Agent: Hammerspoon-remoteState",
  }
  if token then
    table.insert(headers, "-H")
    table.insert(headers, "Authorization: Bearer " .. token)
  end
  if extra then
    for _, h in ipairs(extra) do
      table.insert(headers, h)
    end
  end
  return headers
end

local function githubGet(path, etag, callback)
  local args = apiHeaders(etag and { "-H", "If-None-Match: " .. etag } or nil)
  table.insert(args, contentsUrl(path))
  curlToFile(args, function(exitCode, body, headers)
    if exitCode ~= 0 then
      callback({ ok = false, err = "curl exit " .. tostring(exitCode) })
      return
    end
    local status, map = parseHttp(headers)
    if status == 304 then
      callback({ ok = true, notModified = true, status = 304, etag = map["etag"] or etag })
      return
    end
    if status ~= 200 then
      callback({
        ok = false,
        status = status,
        err = "HTTP " .. tostring(status) .. " " .. (body or ""):sub(1, 180),
      })
      return
    end
    local decoded = hs.json.decode(body)
    if type(decoded) ~= "table" then
      callback({ ok = false, err = "invalid github json" })
      return
    end
    local b64 = (decoded.content or ""):gsub("%s+", "")
    local text = ""
    if b64 ~= "" then
      text = hs.base64.decode(b64) or ""
    end
    callback({
      ok = true,
      status = 200,
      sha = decoded.sha,
      text = text,
      etag = map["etag"],
    })
  end)
end

local function githubPut(path, text, sha, message, callback)
  local payload = {
    message = message,
    content = hs.base64.encode(text or ""),
    sha = sha,
  }
  local encoded = hs.json.encode(payload)
  local args = apiHeaders({
    "-H", "Content-Type: application/json",
    "-X", "PUT",
    "--data-binary", encoded,
  })
  table.insert(args, contentsUrl(path))
  curlToFile(args, function(exitCode, body, headers)
    if exitCode ~= 0 then
      callback({ ok = false, err = "curl exit " .. tostring(exitCode) })
      return
    end
    local status = parseHttp(headers)
    if status ~= 200 and status ~= 201 then
      callback({
        ok = false,
        status = status,
        err = "HTTP " .. tostring(status) .. " " .. (body or ""):sub(1, 180),
      })
      return
    end
    callback({ ok = true, status = status })
  end)
end

local function decodeDesired(text)
  if not text then return nil, "empty" end
  text = text:gsub("^\239\187\191", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil, "empty" end
  local jsonText = text:match("%b{}")
  if not jsonText then return nil, "no json object" end
  local ok, data = pcall(hs.json.decode, jsonText)
  if not ok or type(data) ~= "table" then
    return nil, "invalid json"
  end
  return data, nil
end

-- 只看界面进程 UURemote。不碰 launchd，也不杀 UURemoteDaemon。
local function isUURemoteRunning()
  local out = hs.execute("/usr/bin/pgrep -x UURemote") or ""
  return out:match("%d") ~= nil
end

-- SIGTERM 会被 UU 拦成「是否退出」对话框。SIGKILL 才能真正关掉。
local function killUURemoteExceptDaemon()
  local out = hs.execute("/bin/ps -axo pid=,command=") or ""
  for line in out:gmatch("[^\n]+") do
    if line:find("/Applications/UURemote.app", 1, true)
        and not line:find("UURemoteDaemon", 1, true) then
      local pid = line:match("^%s*(%d+)")
      if pid then
        hs.execute("/bin/kill -9 " .. pid .. " >/dev/null 2>&1", true)
      end
    end
  end
end

local function setUURemote(desired)
  local running = isUURemoteRunning()

  if desired == "running" then
    if running then return false, "already running" end
    if scheduledApps and scheduledApps.openUURemote then
      scheduledApps.openUURemote()
    else
      hs.application.launchOrFocus("UURemote")
    end
    return true, "started"
  end

  if desired == "stopped" then
    if not running then return false, "already stopped" end
    killUURemoteExceptDaemon()
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
  -- 内置屏常见只能落到相邻整数；差 1 就当对齐，避免 82↔83 每轮空打。
  if cur and math.abs(cur - n) <= 1 then
    return false, "already " .. tostring(cur)
  end
  if state.brightnessSettled and state.brightnessSettled.desired == n
      and state.brightnessSettled.actual == cur then
    return false, "hardware settled at " .. tostring(cur)
  end
  local ok = hs.brightness.set(n)
  if not ok then
    return false, "set failed"
  end
  local after = currentBrightness()
  if after then
    state.brightnessSettled = { desired = n, actual = after }
    if math.abs(after - n) <= 1 then
      if after == n then
        return true, (cur and (tostring(cur) .. " -> " .. tostring(n)) or ("set " .. tostring(n)))
      end
      return false, "already " .. tostring(after)
    end
  end
  return true, (cur and (tostring(cur) .. " -> " .. tostring(n)) or ("set " .. tostring(n)))
end

local function caffeinatePids()
  return hs.execute("/usr/bin/pgrep -f '/usr/bin/caffeinate -dims'") or ""
end

local function stopCaffeinateProcess()
  if state.caffeinateTask then
    pcall(function() state.caffeinateTask:terminate() end)
    state.caffeinateTask = nil
  end
  hs.execute("/usr/bin/pkill -f '/usr/bin/caffeinate -dims' >/dev/null 2>&1", true)
  hs.caffeinate.set("system", false)
  hs.caffeinate.set("systemIdle", false)
  hs.caffeinate.set("displayIdle", false)
end

local function isCaffeinateRunning()
  if state.caffeinateTask and state.caffeinateTask:isRunning() then
    return true
  end
  if hs.caffeinate.get("system") == true then
    return true
  end
  return caffeinatePids():match("%d") ~= nil
end

-- 盖上盖子后系统仍可能睡；在交流电下 PreventSystemSleep 才能撑住。
-- hs.caffeinate 会在 hs.reload() 时丢掉 assertion，所以再挂一个常驻 caffeinate 进程。
local function setCaffeinate(desired)
  if desired == "running" then
    if isCaffeinateRunning() then return false, "already running" end
    stopCaffeinateProcess()
    local task = hs.task.new("/usr/bin/caffeinate", function()
      state.caffeinateTask = nil
    end, { "-dims" })
    if not task then
      hs.caffeinate.set("system", true)
      hs.caffeinate.set("systemIdle", true)
      if hs.caffeinate.get("system") then
        return true, "started (assertion only)"
      end
      return false, "start failed"
    end
    state.caffeinateTask = task
    task:start()
    hs.caffeinate.set("system", true)
    hs.caffeinate.set("systemIdle", true)
    return true, "started"
  end

  if desired == "stopped" then
    if not isCaffeinateRunning() then return false, "already stopped" end
    stopCaffeinateProcess()
    return true, "stopped"
  end

  return false, "unsupported value " .. tostring(desired)
end

local function trimLog(text)
  text = (text or ""):gsub("\r\n", "\n")
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

  githubGet(LOG_PATH, nil, function(res)
    if not res.ok then
      log("log get failed: " .. tostring(res.err))
      if callback then callback(false) end
      return
    end
    local current = trimLog(res.text)
    local nextText = current == "" and added or (current .. "\n" .. added)
    if not nextText:match("\n$") then
      nextText = nextText .. "\n"
    end
    githubPut(LOG_PATH, nextText, res.sha, "append remoteState log", function(putRes)
      if not putRes.ok then
        log("log put failed: " .. tostring(putRes.err))
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
    if sysSpec.caffeinate ~= nil then
      local value = sysSpec.caffeinate
      if value ~= "running" and value ~= "stopped" then
        table.insert(changes, "caffeinate: 忽略非法值 " .. tostring(value))
      else
        local applied, detail = setCaffeinate(value)
        if applied then
          table.insert(changes, "caffeinate: " .. detail)
          notify("防休眠已" .. (value == "running" and "开启" or "关闭"))
        else
          log("caffeinate noop: " .. tostring(detail))
        end
      end
    end
  end

  return changes
end

local function tick()
  if state.busy then return end
  if not loadToken() then
    if not state.tokenWarned then
      state.tokenWarned = true
      log("no GitHub token: put one in private/github.lua or login with gh")
    end
    return
  end
  state.busy = true

  githubGet(DESIRED_PATH, state.desiredEtag, function(res)
    if not res.ok then
      log("desired get failed: " .. tostring(res.err))
      state.busy = false
      return
    end

    local desired = state.cachedDesired
    if res.notModified then
      if not desired then
        state.busy = false
        return
      end
    else
      if res.etag then state.desiredEtag = res.etag end
      if res.sha then state.desiredSha = res.sha end
      local parsed, err = decodeDesired(res.text)
      if not parsed then
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
      desired = parsed
      state.cachedDesired = parsed
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
  state.desiredEtag = nil
  tick()
end

function M.status()
  local uu = isUURemoteRunning() and "running" or "stopped"
  local caffeinate = isCaffeinateRunning() and "running" or "stopped"
  local brightness = currentBrightness()
  log("actual uuremote=" .. uu .. " caffeinate=" .. caffeinate
    .. " brightness=" .. tostring(brightness) .. " repo=" .. OWNER .. "/" .. REPO)
  return { uuremote = uu, caffeinate = caffeinate, brightness = brightness }
end

state.timer = hs.timer.doEvery(INTERVAL, tick)
hs.timer.doAfter(3, tick)
log("Loaded, polling GitHub " .. OWNER .. "/" .. REPO .. " every " .. tostring(INTERVAL) .. "s")

return M
