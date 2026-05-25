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

local function muteOnWorkWifi()
    local currentWifi = hs.wifi.currentNetwork()
    local currentOutput = hs.audiodevice.current(false)
    if not currentWifi or not currentOutput then return end

    if (isWorkWifi(currentWifi) and currentOutput.name == outputDeviceName) then
        local outputDevice = hs.audiodevice.findDeviceByName(outputDeviceName)
        if outputDevice then
            outputDevice:setOutputMuted(true)
        end
        hs.notify.new({title="HS Robot", informativeText="Connect to Company And Audio Mute"}):send()
    end
end

if hasWorkWifiConfig() then
    wifiWatcher = hs.wifi.watcher.new(muteOnWorkWifi)
    wifiWatcher:start()
    muteOnWorkWifi()
end
