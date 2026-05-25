local function Chinese()
    if chineseInputSourceID then
        hs.keycodes.currentSourceID(chineseInputSourceID)
    end
end

local function English()
    if englishInputSourceID then
        hs.keycodes.currentSourceID(englishInputSourceID)
    end
end

local function updateAppInputMethod(appObject)
    if not appObject then return end
    local focusAppPath = appObject:path()

    for _, app in pairs(appInputMethod) do
        local appPath = app[1]
        local expectedIme = app[2]

        if focusAppPath == appPath then
            if expectedIme == 'English' then
                English()
            else
                Chinese()
            end
            break
        end
    end
end

-- helper hotkey to figure out the app path and name of current focused window
hs.hotkey.bind({'ctrl', 'cmd'}, ".", function()
    local win = hs.window.focusedWindow()
    if not win then return end

    local appObject = win:application()
    if not appObject then return end

    hs.alert.show("App path:        "
    ..appObject:path()
    .."\n"
    .."App name:      "
    ..appObject:name()
    .."\n"
    .."IM source id:  "
    ..hs.keycodes.currentSourceID())
end)

-- Handle cursor focus and application's screen manage.
local function applicationWatcher(appName, eventType, appObject)
    if (eventType == hs.application.watcher.activated) then
        updateAppInputMethod(appObject)
    end
end

appWatcher = hs.application.watcher.new(applicationWatcher)
appWatcher:start()
