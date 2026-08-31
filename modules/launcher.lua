hs.fnutils.each(applist, function(entry)
    hs.hotkey.bind(launcherHotkey, entry.shortcut, entry.appname, function()
        if (entry.appname == "WeChat" or entry.appname == "微信")
            and wechatPrivacy and wechatPrivacy.isProtected
            and wechatPrivacy.isProtected() then
            hs.notify.new({
                title = "HS Robot",
                informativeText = "会议或外接显示器期间不允许打开微信。",
            }):send()
            return
        end
        hs.application.launchOrFocus(entry.appname)
    end)
end)
