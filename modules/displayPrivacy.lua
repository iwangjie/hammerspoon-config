local screen = require "hs.screen"
local settings = require "hs.settings"
local timer = require "hs.timer"

local module = {
    isPresenting = false,
}

local settingKey = "externalDisplayPresenting"
local hasPresentingState = false
local presentingCallbacks = {}
local refreshTimer

local function updatePresentingState()
    refreshTimer = nil

    local isPresenting = #screen.allScreens() > 1
    if hasPresentingState and module.isPresenting == isPresenting then return end

    module.isPresenting = isPresenting
    hasPresentingState = true
    settings.set(settingKey, isPresenting)
    for _, callback in pairs(presentingCallbacks) do
        callback(isPresenting)
    end
end

local function scheduleUpdate()
    if refreshTimer then return end

    refreshTimer = timer.doAfter(0.2, updatePresentingState)
end

function module:subscribe(identifier, callback)
    presentingCallbacks[identifier] = callback
    if hasPresentingState then callback(module.isPresenting) end
    return module
end
function module:unsubscribe(identifier)
    presentingCallbacks[identifier] = nil
    return module
end
module.watcher = screen.watcher.new(scheduleUpdate)
module.watcher:start()
scheduleUpdate()

return module
