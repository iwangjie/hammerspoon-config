wifiWatcher = hs.wifi.watcher.new(function()
    if not workWifi then return end

    local currentWifi = hs.wifi.currentNetwork()
    local currentOutput = hs.audiodevice.current(false)
    if not currentWifi or not currentOutput then return end

    if (currentWifi == workWifi and currentOutput.name == outputDeviceName) then
        -- audio mute 
        local outputDevice = hs.audiodevice.findDeviceByName(outputDeviceName)
        if outputDevice then
            outputDevice:setOutputMuted(true)
        end
        hs.notify.new({title="HS Robot", informativeText="Connect to Company And Audio Mute"}):send()
    end
end)
wifiWatcher:start()
