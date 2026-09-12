local Device = require("device")
local ffiUtil = require("ffi/util")

local Screen = Device.screen
local StripReveal = {}

local SHAPE_BANDS = 24

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

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
    local shape = config.shape or "straight"
    if waveform == "auto" and not Screen.refreshUI then
        return nil, "AUTO/UI refresh is unavailable on this device."
    elseif waveform == "du" and not Screen.refreshFast then
        return nil, "DU/Fast refresh is unavailable on this device."
    elseif waveform == "a2" and not Screen.refreshA2 then
        return nil, "A2 refresh is unavailable on this device."
    elseif waveform ~= "auto" and waveform ~= "du" and waveform ~= "a2" then
        return nil, "Unknown strip waveform: " .. tostring(waveform)
    end
    if shape ~= "straight" and shape ~= "diagonal" and shape ~= "bottom_curve" then
        return nil, "Unknown reveal shape: " .. tostring(shape)
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

local function submitRegion(waveform, x, y, w, h)
    if w <= 0 or h <= 0 then return nil end
    local before = Screen.marker
    if waveform == "a2" then
        Screen:refreshA2(x, y, w, h)
    elseif waveform == "du" then
        Screen:refreshFast(x, y, w, h)
    else
        -- Original KPW4 ZIP path. On Kindle Rex KOReader's UI refresh maps
        -- to the AUTO waveform.
        Screen:refreshUI(x, y, w, h)
    end
    if Screen.marker and Screen.marker ~= before then
        return Screen.marker
    end
end

-- Return how much of a horizontal band has been revealed (0..1).
-- All shapes start together at 0 and finish aligned at 1. The shaped modes use
-- a p*(1-p) envelope so their lead disappears naturally at the final frame.
local function shapedProgress(shape, progress, y_norm)
    if shape == "diagonal" then
        -- Bottom is ahead, top is behind. The edge remains approximately
        -- diagonal while both ends converge to a straight edge at completion.
        local envelope = 4 * progress * (1 - progress)
        return clamp(progress + 0.22 * (y_norm - 0.5) * envelope, 0, 1)
    elseif shape == "bottom_curve" then
        -- A curved bottom-corner flip. Bottom bands accelerate early, then slow
        -- relative to the top so the entire edge straightens before finishing.
        local envelope = 4 * progress * (1 - progress)
        local bottom_weight = y_norm * y_norm
        return clamp(progress + 0.18 * bottom_weight * envelope, 0, 1)
    end
    return progress
end

-- KPW4 reveal: six temporal steps. Straight mode exactly retains the original
-- full-height vertical strip behavior. Shaped modes divide the page into a few
-- horizontal bands in RAM, but still submit only ONE panel update per step: the
-- bounding rectangle containing every newly revealed band. This preserves the
-- cheap six-update display path instead of issuing dozens of E-Ink updates.
function StripReveal.run(old, new, direction, config)
    config = config or {}
    local ready, why = StripReveal.preflight(config)
    if not ready then error(why) end

    local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()
    local steps = 6
    local delay_ms = math.max(0, tonumber(config.delay_ms) or 40)
    local scheduler = config.scheduler == "fixed" and "fixed" or "free"
    local waveform = config.waveform or "auto"
    local shape = config.shape or "straight"
    local band_count = shape == "straight" and 1 or SHAPE_BANDS
    local band_h = math.ceil(sh / band_count)
    local previous = {}
    local last_marker
    local started = nowSeconds()

    for band = 1, band_count do previous[band] = 0 end
    Screen.bb:blitFrom(old, 0, 0, 0, 0, sw, sh)

    for i = 1, steps do
        -- Fixed mode targets absolute strip times, so drawing/submit overhead
        -- does not accumulate into progressively later frames.
        if scheduler == "fixed" and i > 1 and delay_ms > 0 then
            local deadline = started + ((i - 1) * delay_ms / 1000)
            local now = nowSeconds()
            if now < deadline then
                ffiUtil.usleep(math.floor((deadline - now) * 1000000))
            end
        end

        local progress = i / steps
        local dirty_left = sw
        local dirty_right = 0
        local changed = false

        for band = 1, band_count do
            local y = (band - 1) * band_h
            if y >= sh then break end
            local bh = math.min(band_h, sh - y)
            local y_norm = (y + bh * 0.5) / sh
            local local_progress = shapedProgress(shape, progress, y_norm)
            local dx = math.floor(sw * local_progress + 0.5)
            local prev_dx = previous[band] or 0

            -- The formulas above are monotonic, but keep this guard so a future
            -- shape can never try to "unreveal" pixels and create ghost trails.
            if dx < prev_dx then dx = prev_dx end
            if i == steps then dx = sw end

            local changed_w = dx - prev_dx
            if changed_w > 0 then
                local x
                if direction > 0 then
                    x = sw - dx
                    Screen.bb:blitFrom(new, x, y, x, y, changed_w, bh)
                else
                    x = prev_dx
                    Screen.bb:blitFrom(new, x, y, x, y, changed_w, bh)
                end
                dirty_left = math.min(dirty_left, x)
                dirty_right = math.max(dirty_right, x + changed_w)
                changed = true
            end
            previous[band] = dx
        end

        if changed and dirty_right > dirty_left then
            -- One E-Ink update per temporal step. For shaped edges this box is
            -- wider than the actually changed pixels, but avoids many small
            -- panel submissions and keeps the animation smooth on PW4.
            last_marker = submitRegion(
                waveform, dirty_left, 0, dirty_right - dirty_left, sh) or last_marker
        end

        if scheduler == "free" then
            sleepMs(delay_ms)
        end
    end

    waitMarker(last_marker)
    Screen.bb:blitFrom(new, 0, 0, 0, 0, sw, sh)
    return {
        style = "strip",
        shape = shape,
        frames = steps,
        delay_ms = delay_ms,
        scheduler = scheduler,
        waveform = waveform,
        elapsed = nowSeconds() - started,
    }
end

return StripReveal
