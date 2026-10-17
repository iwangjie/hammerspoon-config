local M = {}

local CURL = "/usr/bin/curl"
local GH = remoteStateGh or "/opt/homebrew/bin/gh"
local OWNER = remoteStateOwner or "iwangjie"
local REPO = remoteStateRepo or "mac-remote-state"
local DESIRED_PATH = remoteStateDesiredPath or "desired.json"
local LOG_PATH = remoteStateLogPath or "log.md"
local INTERVAL = tonumber(remoteStateInterval) or 60  -- 改成 60 秒
local IDLE_INTERVAL = tonumber(remoteStateIdleInterval) or 120
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
  syncEnabled = true,
}