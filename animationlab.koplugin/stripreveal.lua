local Device = require("device")
local ffiUtil = require("ffi/util")

local Screen = Device.screen
local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local Dither = dofile(plugin_dir .. "pagedither.lua")

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

local function softwareMode(mode)
    if mode == "sw_bayer" then return "ordered_binary" end
    if mode == "sw_stochastic" then return "stochastic_binary" end
    if mode == "sw_floyd_steinberg" then return "floyd_steinberg" end
    if mode == "sw_atkinson" then return "atkinson" end
    if mode == "threshold" then return "threshold" end
end

function StripReveal.preflight(config)
    config = config or {}
    if not Screen.refreshUI then
        return nil, "UI refresh is unavailable on this device."
    end
    if softwareMode(config.dither) and Screen.bb:getBpp() ~= 8 then
        return nil, "Selected software dithering requires an 8bpp framebuffer."
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

local function submitStrip(x, y, w, h)
    local before = Screen.marker
    Screen:refreshUI(x, y, w, h)
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
    local scheduler = config.scheduler or "free"
    local queue_depth = math.max(1, tonumber(config.queue_depth) or 4)
    local dither_mode = softwareMode(config.dither)
    local prev_dx = 0
    local markers = {}
    local fallback_outstanding = 0
    local last_marker
    local started = nowSeconds()

    Screen.bb:blitFrom(old, 0, 0, 0, 0, sw, sh)

    for i = 1, steps do
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
            if dither_mode then
                Dither.applyRect(Screen.bb, strip_x, 0, strip_w, sh, dither_mode)
            end

            local marker = submitStrip(strip_x, 0, strip_w, sh)
            last_marker = marker or last_marker

            if scheduler == "sync" then
                waitMarker(marker)
            elseif scheduler == "bounded" then
                if marker then
                    markers[#markers + 1] = marker
                    if #markers > queue_depth then
                        waitMarker(table.remove(markers, 1))
                    end
                else
                    fallback_outstanding = fallback_outstanding + 1
                    if fallback_outstanding >= queue_depth then
                        if Screen.refreshWaitForLast then Screen:refreshWaitForLast() end
                        fallback_outstanding = 0
                    end
                end
            end
        end

        prev_dx = dx
        if scheduler ~= "fixed" then
            sleepMs(delay_ms)
        end
    end

    if scheduler == "bounded" then
        for _, marker in ipairs(markers) do
            waitMarker(marker)
        end
        if fallback_outstanding > 0 and Screen.refreshWaitForLast then
            Screen:refreshWaitForLast()
        end
    elseif scheduler == "free" or scheduler == "fixed" then
        waitMarker(last_marker)
    end

    Screen.bb:blitFrom(new, 0, 0, 0, 0, sw, sh)
    return {
        style = "strip",
        frames = steps,
        delay_ms = delay_ms,
        scheduler = scheduler,
        dither = config.dither or "gray",
        elapsed = nowSeconds() - started,
    }
end

return StripReveal
