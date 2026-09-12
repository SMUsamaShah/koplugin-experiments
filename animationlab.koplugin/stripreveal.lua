local Device = require("device")
local ffiUtil = require("ffi/util")

local Screen = Device.screen
local StripReveal = {}

local function nowSeconds()
    local s, us = ffiUtil.gettime()
    return s + us / 1000000
end

local function sleepMs(ms)
    if ms and ms > 0 then
        ffiUtil.usleep(math.floor(ms * 1000))
    end
end

function StripReveal.preflight(config)
    config = config or {}
    local waveform = config.waveform or "auto"
    if waveform == "auto" and not Screen.refreshUI then
        return nil, "AUTO/UI refresh is unavailable on this device."
    elseif waveform == "du" and not Screen.refreshFast then
        return nil, "DU/Fast refresh is unavailable on this device."
    elseif waveform == "a2" and not Screen.refreshA2 then
        return nil, "A2 refresh is unavailable on this device."
    elseif waveform ~= "auto" and waveform ~= "du" and waveform ~= "a2" then
        return nil, "Unknown strip waveform: " .. tostring(waveform)
    end
    return true
end

local function waitMarker(marker)
    if marker and Screen.mech_wait_update_complete then
        local ret = Screen:mech_wait_update_complete(marker)
        Screen.dont_wait_for_marker = marker
        return ret
    end
    if Screen.refreshWaitForLast then
        Screen:refreshWaitForLast()
    end
    return 0
end

local function submitStrip(waveform, x, y, w, h)
    local before = Screen.marker
    if waveform == "a2" then
        Screen:refreshA2(x, y, w, h)
    elseif waveform == "du" then
        Screen:refreshFast(x, y, w, h)
    else
        -- This is the original KPW4 ZIP behavior. On Kindle Rex, KOReader's
        -- UI refresh path uses the AUTO waveform.
        Screen:refreshUI(x, y, w, h)
    end
    if Screen.marker and Screen.marker ~= before then
        return Screen.marker
    end
end

-- KPW4 strip reveal: six equal full-height strips. Only the newly revealed
-- strip is refreshed; previous strips remain visible through e-ink bistability.
-- The common repaint hook performs one final full-screen UI-quality settle.
function StripReveal.run(old, new, direction, config)
    config = config or {}
    local ready, why = StripReveal.preflight(config)
    if not ready then error(why) end

    local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()
    local steps = 6
    local delay_ms = math.max(0, tonumber(config.delay_ms) or 40)
    local scheduler = config.scheduler == "fixed" and "fixed" or "free"
    local waveform = config.waveform or "auto"
    local prev_dx = 0
    local last_marker
    local started = nowSeconds()

    Screen.bb:blitFrom(old, 0, 0, 0, 0, sw, sh)

    for i = 1, steps do
        -- Fixed mode targets absolute strip times, so rendering/submit overhead
        -- does not accumulate into progressively later frames.
        if scheduler == "fixed" and i > 1 and delay_ms > 0 then
            local deadline = started + ((i - 1) * delay_ms / 1000)
            local now = nowSeconds()
            if now < deadline then
                ffiUtil.usleep(math.floor((deadline - now) * 1000000))
            end
        end

        local dx = math.floor(sw * (i / steps))
        local strip_w = dx - prev_dx
        local strip_x

        if direction > 0 then
            if sw - dx > 0 then
                Screen.bb:blitFrom(old, 0, 0, 0, 0, sw - dx, sh)
            end
            if dx > 0 then
                Screen.bb:blitFrom(new, sw - dx, 0, sw - dx, 0, dx, sh)
            end
            strip_x = sw - dx
        else
            if dx > 0 then
                Screen.bb:blitFrom(new, 0, 0, 0, 0, dx, sh)
            end
            if sw - dx > 0 then
                Screen.bb:blitFrom(old, dx, 0, dx, 0, sw - dx, sh)
            end
            strip_x = prev_dx
        end

        if strip_w > 0 then
            last_marker = submitStrip(waveform, strip_x, 0, strip_w, sh) or last_marker
        end

        prev_dx = dx
        if scheduler == "free" then
            sleepMs(delay_ms)
        end
    end

    -- Let the last strip update finish before the common hook submits the final
    -- full-screen UI-quality settle refresh.
    waitMarker(last_marker)

    Screen.bb:blitFrom(new, 0, 0, 0, 0, sw, sh)
    return {
        style = "strip",
        frames = steps,
        delay_ms = delay_ms,
        scheduler = scheduler,
        waveform = waveform,
        elapsed = nowSeconds() - started,
    }
end

return StripReveal
