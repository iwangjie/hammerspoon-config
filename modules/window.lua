hs.hotkey.bind(windowHotkey, 'return', function()
    local win = hs.window.focusedWindow()
    if win then
        hs.grid.maximizeWindow(win)
    end
end)

hs.hotkey.bind(windowHotkey, 'F', function() 
    local win = hs.window.focusedWindow()
    if win then
        win:toggleFullScreen()
    end
end)

hs.hotkey.bind(windowHotkey, 'left', function()
    local w = hs.window.focusedWindow()
    if not w then
        return
    end
    local s = w:screen():toWest()
    if s then
        w:moveToScreen(s)
    end
end)

hs.hotkey.bind(windowHotkey, 'right', function()
    local w = hs.window.focusedWindow()
    if not w then
        return
    end
    local s = w:screen():toEast()
    if s then
        w:moveToScreen(s)
    end
end)
