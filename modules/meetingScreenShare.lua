local application = require "hs.application"
local axuielement = require "hs.axuielement"
local settings = require "hs.settings"
local timer = require "hs.timer"

local module = {
    isSharing = false,
}

local meetingBundleID = "com.tencent.wwmapp"
local settingKey = "meetingScreenSharing"
local shareStopLabels = {
    "停止共享",
    "结束共享",
    "停止演示",
    "结束演示",
    "Stop sharing",
    "Stop presenting",
}
local shareAttributes = {
    "AXTitle",
    "AXDescription",
    "AXValue",
    "AXHelp",
    "AXIdentifier",
}

local observer
local refreshTimer
local hasSharingState = false
local stateCallbacks = {}

local function hasShareStopLabel(element)
    for _, attribute in ipairs(shareAttributes) do
        local value = element:attributeValue(attribute)
        if type(value) == "string" then
            for _, label in ipairs(shareStopLabels) do
                if value:find(label, 1, true) then
                    return true
                end
            end
        end
    end

    return false
end

local function findMeetingApplication()
    for _, app in ipairs(application.applicationsForBundleID(meetingBundleID)) do
        if app:isRunning() then return app end
    end
end

local function detectSharing()
    local app = findMeetingApplication()
    if not app then return false end

    local root = axuielement.applicationElement(app)
    local pending = {root}
    local visited = {}

    while #pending > 0 do
        local element = table.remove(pending)
        if not visited[element] then
            visited[element] = true
            if hasShareStopLabel(element) then return true end

            for _, child in ipairs(element:attributeValue("AXChildren") or {}) do
                table.insert(pending, child)
            end
        end
    end

    return false
end

local function refreshSharingState()
    refreshTimer = nil

    local isSharing = detectSharing()
    if hasSharingState and module.isSharing == isSharing then return end

    local wasSharing = module.isSharing
    module.isSharing = isSharing
    hasSharingState = true
    settings.set(settingKey, isSharing)
    for _, callback in pairs(stateCallbacks) do
        callback(isSharing)
    end
    if wasSharing ~= isSharing then
        hs.notify.new({
            title="HS Robot",
            informativeText=isSharing and "Enterprise WeChat Meeting is sharing the screen." or
                "Enterprise WeChat Meeting stopped sharing the screen.",
        }):send()
    end
end

local function scheduleRefresh()
    if refreshTimer then return end

    refreshTimer = timer.doAfter(0.1, refreshSharingState)
end

local function startObserver()
    local app = findMeetingApplication()
    if not app or observer then return end

    local root = axuielement.applicationElement(app)
    observer = axuielement.observer.new(app:pid())
    observer:callback(function()
        scheduleRefresh()
    end)

    for _, notification in ipairs({
        axuielement.observer.notifications.windowCreated,
        axuielement.observer.notifications.uIElementDestroyed,
        axuielement.observer.notifications.focusedWindowChanged,
        axuielement.observer.notifications.valueChanged,
        axuielement.observer.notifications.titleChanged,
    }) do
        local ok, err = pcall(observer.addWatcher, observer, root, notification)
        if not ok then
            print("Meeting screen-share observer skipped " .. notification .. ": " .. err)
        end
    end

    observer:start()
    scheduleRefresh()
end

local function stopObserver()
    if observer then
        observer:stop()
        observer = nil
    end
end

local function watchMeetingApplication(_, eventType, app)
    if app:bundleID() ~= meetingBundleID then return end

    if eventType == application.watcher.launched then
        startObserver()
    elseif eventType == application.watcher.terminated then
        stopObserver()
        if module.isSharing then
            module.isSharing = false
            settings.set(settingKey, false)
        end
    end
end

module.refresh = refreshSharingState
function module:subscribe(identifier, callback)
    stateCallbacks[identifier] = callback
    if hasSharingState then callback(module.isSharing) end
    return module
end
function module:unsubscribe(identifier)
    stateCallbacks[identifier] = nil
    return module
end
module.watcher = application.watcher.new(watchMeetingApplication)
module.watcher:start()
startObserver()

return module
