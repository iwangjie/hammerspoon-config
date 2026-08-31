local application = require "hs.application"
local timer = require "hs.timer"
local window = require "hs.window"
local windowFilter = require "hs.window.filter"

local module = {}

local weChatBundleIDs = {
    ["com.tencent.xinWeChat"] = true,
    ["com.tencent.flue.WeChatAppEx"] = true,
    ["com.tencent.xinWeChat.WeChatHelper"] = true,
}
local meetingBundleIDs = {
    ["com.tencent.wwmapp"] = true,
    ["com.tencent.meeting"] = true,
}
local meetingNames = {
    "企业微信 · 会议",
    "企业微信·会议",
    "wwmapp",
    "腾讯会议",
    "TencentMeeting",
    "Tencent Meeting",
    "VooV Meeting",
}

local lastNotifyAt = 0
local recheckTimer
local meetingWatchTimer
local enforceWeChat

local function appsForBundleID(bundleID)
    return application.applicationsForBundleID(bundleID) or {}
end

local function isMeetingApp(app)
    if not app then return false end

    local bundleID = app:bundleID()
    if bundleID and meetingBundleIDs[bundleID] then return true end

    local name = app:name()
    if not name then return false end
    for _, meetingName in ipairs(meetingNames) do
        if name == meetingName then return true end
    end
    return false
end

local function isWeChatApp(app)
    if not app or isMeetingApp(app) then return false end

    local bundleID = app:bundleID()
    return bundleID and weChatBundleIDs[bundleID] == true
end

local function onscreenWindowIDs()
    if not window._orderedwinids then return nil end

    local ids = {}
    for _, id in ipairs(window._orderedwinids() or {}) do
        ids[id] = true
    end
    return ids
end

local function windowIsOnscreenMeetingUI(win, onscreen)
    if not win then return false end

    local frame = win:frame()
    if not frame or (frame.w or 0) < 80 or (frame.h or 0) < 80 then
        return false
    end

    local id = win:id()
    if not id then return false end
    if onscreen == nil then return not win:isMinimized() end
    return onscreen[id] == true
end

local function collectMeetingApps()
    local apps = {}
    local seen = {}

    local function add(app)
        if not app or seen[app] or not isMeetingApp(app) then return end
        seen[app] = true
        table.insert(apps, app)
    end

    for bundleID in pairs(meetingBundleIDs) do
        for _, app in ipairs(appsForBundleID(bundleID)) do
            add(app)
        end
    end
    for _, name in ipairs(meetingNames) do
        add(application.find(name, true, true))
    end
    return apps
end

local function meetingIsActive(app)
    if not app or not app:isRunning() then return false end

    local bundleID = app:bundleID()
    -- 企业微信会议关窗口后 wwmapp 仍会作为 UIElement 后台残留，不能只看进程。
    if bundleID == "com.tencent.wwmapp" or app:kind() <= 0 then
        local onscreen = onscreenWindowIDs()
        for _, win in ipairs(app:allWindows()) do
            if windowIsOnscreenMeetingUI(win, onscreen) then return true end
        end
        return false
    end

    return true
end

local function anyMeetingActive()
    for _, app in ipairs(collectMeetingApps()) do
        if meetingIsActive(app) then return true end
    end
    return false
end

local function anyMeetingProcess()
    return #collectMeetingApps() > 0
end

function module.isProtected()
    return anyMeetingActive() or (displayPrivacy and displayPrivacy.isPresenting)
end

local function notifyBlocked()
    local now = timer.secondsSinceEpoch()
    if now - lastNotifyAt < 5 then return end

    lastNotifyAt = now
    hs.notify.new({
        title = "HS Robot",
        informativeText = "会议或外接显示器期间不允许打开微信。",
    }):send()
end

local function killWeChat()
    if not module.isProtected() then return false end

    local killed = false
    for bundleID in pairs(weChatBundleIDs) do
        for _, app in ipairs(appsForBundleID(bundleID)) do
            if isWeChatApp(app) and app:isRunning() then
                app:kill9()
                killed = true
            end
        end
    end

    if killed then notifyBlocked() end
    return killed
end

local function scheduleRecheck()
    if recheckTimer then return end

    recheckTimer = timer.doAfter(0.8, function()
        recheckTimer = nil
        if killWeChat() then scheduleRecheck() end
    end)
end

local function refreshMeetingWatch()
    if anyMeetingProcess() then
        if not meetingWatchTimer then
            meetingWatchTimer = timer.doEvery(1, function()
                enforceWeChat()
            end)
        end
    elseif meetingWatchTimer then
        meetingWatchTimer:stop()
        meetingWatchTimer = nil
    end
end

enforceWeChat = function()
    refreshMeetingWatch()
    if killWeChat() then scheduleRecheck() end
end

local function watchApplication(_, eventType, app)
    if isWeChatApp(app) then
        if eventType == application.watcher.launching or
            eventType == application.watcher.launched or
            eventType == application.watcher.activated or
            eventType == application.watcher.unhidden then
            enforceWeChat()
        end
        return
    end

    if not isMeetingApp(app) then return end

    if eventType == application.watcher.launched or
        eventType == application.watcher.activated or
        eventType == application.watcher.unhidden or
        eventType == application.watcher.terminated then
        enforceWeChat()
    end
end

module.windowFilter = windowFilter.new(false)
module.windowFilter:setAppFilter("微信", {})
module.windowFilter:setAppFilter("WeChat", {})
module.windowFilter:setAppFilter("企业微信 · 会议", {allowRoles = "*"})
module.windowFilter:setAppFilter("企业微信·会议", {allowRoles = "*"})
module.windowFilter:setAppFilter("wwmapp", {allowRoles = "*"})
module.windowFilter:setAppFilter("腾讯会议", {allowRoles = "*"})
module.windowFilter:setAppFilter("TencentMeeting", {allowRoles = "*"})
module.windowFilter:setAppFilter("Tencent Meeting", {allowRoles = "*"})
module.windowFilter:setAppFilter("VooV Meeting", {allowRoles = "*"})
module.windowFilter:subscribe({
    windowFilter.windowCreated,
    windowFilter.windowFocused,
    windowFilter.windowUnhidden,
    windowFilter.windowUnminimized,
    windowFilter.windowDestroyed,
    windowFilter.windowMinimized,
    windowFilter.windowHidden,
}, enforceWeChat)

displayPrivacy:subscribe("wechatPrivacy", enforceWeChat)

module.watcher = application.watcher.new(watchApplication)
module.watcher:start()
enforceWeChat()

return module
