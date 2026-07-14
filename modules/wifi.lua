local location = require "hs.location"

local function hasWorkWifiConfig()
    return workWifi or (workWifis and #workWifis > 0)
end

local function isWorkWifi(networkName)
    if not networkName then return false end

    if workWifi and networkName == workWifi then
        return true
    end

    for _, wifiName in ipairs(workWifis or {}) do
        if networkName == wifiName then
            return true
        end
    end

    return false
end

local function muteOnWorkWifi(interface)
    local currentWifi
    if interface then
        currentWifi = hs.wifi.currentNetwork(interface)
    else
        currentWifi = hs.wifi.currentNetwork()
    end
    local currentOutput = hs.audiodevice.current(false)
    if not currentWifi or not currentOutput then return end

    if (isWorkWifi(currentWifi) and currentOutput.name == outputDeviceName) then
        if not currentOutput.muted then
            currentOutput.device:setOutputMuted(true)
            hs.notify.new({title="HS Robot", informativeText="Connect to Company And Audio Mute"}):send()
        end
    end
end

local function notifyLocationAccessRequired()
    hs.notify.new({
        title="HS Robot",
        informativeText="Wi-Fi mute requires Location Services access for Hammerspoon.",
    }):send()
end

local function ensureLocationAccess()
    local status = location.authorizationStatus()
    if status == "authorized" then return true end

    if status == "undefined" then
        location.get()
        locationPermissionTimer = hs.timer.doEvery(1, function()
            local updatedStatus = location.authorizationStatus()
            if updatedStatus == "undefined" then return end

            locationPermissionTimer:stop()
            locationPermissionTimer = nil
            if updatedStatus == "authorized" then
                muteOnWorkWifi()
            else
                notifyLocationAccessRequired()
            end
        end)
    else
        notifyLocationAccessRequired()
    end

    return false
end

if hasWorkWifiConfig() then
    wifiWatcher = hs.wifi.watcher.new(function(_, message, interface)
        if message ~= "SSIDChange" then return end

        -- The SSID event can arrive before currentNetwork reflects the new connection.
        wifiMuteTimer = hs.timer.doAfter(1, function()
            muteOnWorkWifi(interface)
        end)
    end)
    wifiWatcher:watchingFor({"SSIDChange"})
    wifiWatcher:start()
    if ensureLocationAccess() then
        muteOnWorkWifi()
    end
end
