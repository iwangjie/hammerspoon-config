local function blueutilPath()
    local candidates = {
        "/opt/homebrew/bin/blueutil",
        "/usr/local/bin/blueutil",
    }

    for _, path in ipairs(candidates) do
        if hs.fs.attributes(path) then
            return path
        end
    end
end

local function bluetoothSwitch(state)
    local path = blueutilPath()
    if not path then
        print("blueutil is not installed; skipping Bluetooth power change")
        return
    end

    hs.execute(path .. " --power " .. tostring(state), true)
end

local function caffeinateCallback(eventType)
    if (eventType == hs.caffeinate.watcher.screensDidSleep) then
      print("screensDidSleep")
    elseif (eventType == hs.caffeinate.watcher.screensDidWake) then
      print("screensDidWake")
    elseif (eventType == hs.caffeinate.watcher.screensDidLock) then
      print("screensDidLock")
      bluetoothSwitch(0)
    elseif (eventType == hs.caffeinate.watcher.screensDidUnlock) then
      print("screensDidUnlock")
      bluetoothSwitch(1)
    end
end

caffeinateWatcher = hs.caffeinate.watcher.new(caffeinateCallback)
caffeinateWatcher:start()
