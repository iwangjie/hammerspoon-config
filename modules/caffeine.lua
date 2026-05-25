local menubar = hs.menubar.new()

local function hasWeekday(weekday)
    for _, enabledWeekday in ipairs((sleepPreventSchedule or {}).weekdays or {}) do
        if weekday == enabledWeekday then
            return true
        end
    end

    return false
end

local function previousWeekday(weekday)
    if weekday == 1 then
        return 7
    end

    return weekday - 1
end

local function minutes(hour, minute)
    return hour * 60 + minute
end

local function isScheduledTime(timestamp)
    local schedule = sleepPreventSchedule
    if not schedule or not schedule.enabled then
        return false
    end

    local date = os.date("*t", timestamp)
    local currentMinutes = minutes(date.hour, date.min)
    local startMinutes = minutes(schedule.startHour, schedule.startMinute)
    local endMinutes = minutes(schedule.endHour, schedule.endMinute)

    if startMinutes <= endMinutes then
        return hasWeekday(date.wday)
            and currentMinutes >= startMinutes
            and currentMinutes < endMinutes
    end

    return (hasWeekday(date.wday) and currentMinutes >= startMinutes)
        or (hasWeekday(previousWeekday(date.wday)) and currentMinutes < endMinutes)
end

local function setMenuIcon()
    if not menubar then return end

    if hs.caffeinate.get("system") then
        menubar:setTitle("🟢")
    else
        menubar:setTitle("⭕️")
    end
end

local function applySleepState()
    hs.caffeinate.set("system", isScheduledTime(os.time()))
    setMenuIcon()
end

local function candidateTime(baseDate, dayOffset, hour, minute)
    return os.time({
        year = baseDate.year,
        month = baseDate.month,
        day = baseDate.day + dayOffset,
        hour = hour,
        min = minute,
        sec = 0,
    })
end

local function nextBoundaryDelay()
    local schedule = sleepPreventSchedule
    if not schedule or not schedule.enabled then
        return nil
    end

    local now = os.time()
    local baseDate = os.date("*t", now)
    local currentState = isScheduledTime(now)

    for dayOffset = 0, 8 do
        for _, boundary in ipairs({
            {hour = schedule.startHour, minute = schedule.startMinute},
            {hour = schedule.endHour, minute = schedule.endMinute},
        }) do
            local timestamp = candidateTime(baseDate, dayOffset, boundary.hour, boundary.minute)
            if timestamp > now and isScheduledTime(timestamp + 1) ~= currentState then
                return timestamp - now
            end
        end
    end

    return nil
end

local function scheduleNextBoundary()
    applySleepState()

    local delay = nextBoundaryDelay()
    if delay then
        caffeineTimer = hs.timer.doAfter(delay, scheduleNextBoundary)
    end
end

if menubar then
    menubar:setTooltip("系统防休眠状态")
end

scheduleNextBoundary()
