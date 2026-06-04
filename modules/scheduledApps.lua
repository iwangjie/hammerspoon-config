scheduledApps = scheduledApps or {}
scheduledAppTimers = scheduledAppTimers or {}

function scheduledApps.openUURemote()
    hs.application.launchOrFocus("UURemote")
end

function scheduledApps.killUURemote()
    hs.execute("launchctl bootout gui/$(id -u) com.netease.uuremote.agent >/dev/null 2>&1", true)
    hs.execute("pkill -f /Applications/UURemote.app", true)
end

scheduledAppTimers.openUURemote = hs.timer.doAt("06:00", "1d", scheduledApps.openUURemote)
scheduledAppTimers.killUURemote = hs.timer.doAt("10:00", "1d", scheduledApps.killUURemote)
