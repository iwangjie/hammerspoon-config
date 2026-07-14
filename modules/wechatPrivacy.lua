local application = require "hs.application"
local windowFilter = require "hs.window.filter"

local module = {}

local weChatBundleID = "com.tencent.xinWeChat"

local function isProtected()
    return (meetingScreenShare and meetingScreenShare.isSharing) or
        (displayPrivacy and displayPrivacy.isPresenting)
end

local function hideWeChat()
    if not isProtected() then return end

    for _, app in ipairs(application.applicationsForBundleID(weChatBundleID)) do
        for _, window in ipairs(app:allWindows()) do
            if not window:isMinimized() then window:minimize() end
        end
        app:hide()
    end
end

local function watchWeChatApplication(_, eventType, app)
    if not app or app:bundleID() ~= weChatBundleID then return end

    if eventType == application.watcher.activated or
        eventType == application.watcher.unhidden then
        hideWeChat()
    end
end

module.windowFilter = windowFilter.new(false)
module.windowFilter:setAppFilter("微信", {})
module.windowFilter:subscribe({
    windowFilter.windowCreated,
    windowFilter.windowFocused,
    windowFilter.windowUnhidden,
    windowFilter.windowUnminimized,
}, hideWeChat)

meetingScreenShare:subscribe("wechatPrivacy", hideWeChat)
displayPrivacy:subscribe("wechatPrivacy", hideWeChat)

module.watcher = application.watcher.new(watchWeChatApplication)
module.watcher:start()

return module
