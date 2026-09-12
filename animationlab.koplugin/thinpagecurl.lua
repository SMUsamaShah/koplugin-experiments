local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local ffi = require("ffi")
local ffiUtil = require("ffi/util")

local Screen = Device.screen
local C = ffi.C
local has_mxcfb = pcall(require, "ffi/mxcfb_kindle_h")
local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local Dither = dofile(plugin_dir .. "pagedither.lua")

local ThinCurl = {}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function nowSeconds()
    local s, us = ffiUtil.gettime()
    return s + us / 1000000
end

local function sleepSeconds(seconds)
    if seconds and seconds > 0 then ffiUtil.usleep(math.floor(seconds * 1000000)) end
end

local function sleepMs(ms)
    if ms and ms > 0 then ffiUtil.usleep(math.floor(ms * 1000)) end
end

local function smoothstep(t)
    return t * t * (3 - 2 * t)
end

local function isHardwareDither(mode)
    return mode == "hw_ordered" or mode == "hw_floyd_steinberg" or mode == "hw_atkinson"
end

local function softwareMode(mode)
    if mode == "sw_bayer" then return "ordered_binary" end
    if mode == "sw_stochastic" then return "stochastic_binary" end
    if mode == "sw_floyd_steinberg" then return "floyd_steinberg" end
    if mode == "sw_atkinson" then return "atkinson" end
    if mode == "threshold" then return "threshold" end
end

local function rawAvailable()
    return has_mxcfb and Device:isKindle() and Device:isRex()
        and Screen.fd ~= nil and Screen._get_next_marker ~= nil
end

function ThinCurl.preflight(config)
    config = config or {}
    if isHardwareDither(config.dither) and not rawAvailable() then
        return nil, "Selected hardware dithering requires the Kindle Rex direct ioctl path."
    end
    if softwareMode(config.dither) and Screen.bb:getBpp() ~= 8 then
        return nil, "Selected software dithering currently requires an 8bpp framebuffer."
    end
    if config.waveform == "a2" and not Screen.refreshA2 and not rawAvailable() then
        return nil, "A2 refresh is unavailable on this device."
    end
    return true
end

local function waitMarker(marker)
    if marker and Screen.mech_wait_update_complete then
        local ret = Screen:mech_wait_update_complete(marker)
        Screen.dont_wait_for_marker = marker
        return ret
    end
    if Screen.refreshWaitForLast then Screen:refreshWaitForLast() end
    return 0
end

local function hwDitherConstant(mode)
    if mode == "hw_ordered" then return C.EPDC_FLAG_USE_DITHERING_ORDERED end
    if mode == "hw_floyd_steinberg" then return C.EPDC_FLAG_USE_DITHERING_FLOYD_STEINBERG end
    if mode == "hw_atkinson" then return C.EPDC_FLAG_USE_DITHERING_ATKINSON end
end

local function waveformConstant(name)
    if name == "a2" then return C.WAVEFORM_MODE_ZELDA_A2 end
    return C.WAVEFORM_MODE_DU
end

local function rawRexUpdate(waveform, x, y, w, h, dither_mode)
    local bb = Screen.full_bb or Screen.bb
    local align = dither_mode and (Screen.dither_alignment_constraint or 8) or Screen.alignment_constraint
    x, y, w, h = bb:getBoundedRect(x, y, w, h, align)
    x, y, w, h = bb:getPhysicalRect(x, y, w, h)
    w = w * (Screen.refresh_pixel_size or 1)
    if w <= 1 or h <= 1 then return nil end
    if Screen.mech_poweron then Screen:mech_poweron() end

    local u = ffi.new("struct mxcfb_update_data_rex[1]")
    local d = u[0]
    d.update_region.left = x
    d.update_region.top = y
    d.update_region.width = w
    d.update_region.height = h
    d.waveform_mode = waveform
    d.update_mode = C.UPDATE_MODE_PARTIAL
    local marker = Screen:_get_next_marker()
    d.update_marker = marker
    d.temp = C.TEMP_USE_ZELDA_AUTO
    d.flags = 0
    if dither_mode then
        d.dither_mode = dither_mode
        d.quant_bit = 1
    else
        d.dither_mode = C.EPDC_FLAG_USE_DITHERING_PASSTHROUGH
        d.quant_bit = 0
    end
    d.hist_bw_waveform_mode = C.WAVEFORM_MODE_DU
    d.hist_gray_waveform_mode = C.WAVEFORM_MODE_GC16
    if C.ioctl(Screen.fd, C.MXCFB_SEND_UPDATE_REX, u) == -1 then
        error("MXCFB_SEND_UPDATE_REX failed, errno " .. tostring(ffi.errno()))
    end
    return marker
end

local function submitRefresh(config, x, y, w, h)
    if w <= 0 or h <= 0 then return nil end
    if isHardwareDither(config.dither) then
        return rawRexUpdate(waveformConstant(config.waveform), x, y, w, h, hwDitherConstant(config.dither))
    end
    local before = Screen.marker
    if config.waveform == "a2" then Screen:refreshA2(x, y, w, h)
    else Screen:refreshFast(x, y, w, h) end
    if Screen.marker and Screen.marker ~= before then return Screen.marker end
end

local function toneRect(x, y, w, h, darkness, dither)
    local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()
    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    if x < 0 then w, x = w + x, 0 end
    if y < 0 then h, y = h + y, 0 end
    if x + w > sw then w = sw - x end
    if y + h > sh then h = sh - y end
    if w <= 0 or h <= 0 then return end
    Screen.bb:paintRect(x, y, w, h, Blitbuffer.gray(clamp(darkness, 0, 1)))
    local mode = softwareMode(dither)
    if mode then Dither.applyRect(Screen.bb, x, y, w, h, mode) end
end

local function renderFrame(old, new, direction, t, previous_base, config)
    local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()
    local eased = smoothstep(t)
    local phase = math.sin(math.pi * eased)
    local base = direction > 0 and sw * (1 - eased) or sw * eased

    -- Much thinner than the original curl: roughly 40% of its bow/fold/shadow.
    local curve_amp = sw * 0.012 * phase
    local fold_w = sw * 0.028 * phase
    local shadow_w = sw * 0.014 * phase
    local band_h = math.max(18, math.floor(sh / 64))
    local margin = curve_amp + fold_w + shadow_w + 5
    local dirty_x = math.floor(math.max(0, math.min(previous_base, base) - margin))
    local dirty_r = math.floor(math.min(sw, math.max(previous_base, base) + margin))

    local y = 0
    while y < sh do
        local bh = math.min(band_h, sh - y)
        local yn = (y + bh * 0.5) / sh
        local bow = math.sin(math.pi * yn)
        local edge = direction > 0
            and clamp(base + curve_amp * bow * bow, 0, sw)
            or clamp(base - curve_amp * bow * bow, 0, sw)

        if direction > 0 then
            local old_w = math.max(0, math.min(dirty_r, edge) - dirty_x)
            if old_w > 0 then Screen.bb:blitFrom(old, dirty_x, y, dirty_x, y, old_w, bh) end
            local new_x = math.max(dirty_x, math.floor(edge))
            local new_w = dirty_r - new_x
            if new_w > 0 then Screen.bb:blitFrom(new, new_x, y, new_x, y, new_w, bh) end

            local fw = math.min(fold_w, sw - edge)
            local shadow = math.min(shadow_w, sw - edge - fw)
            if shadow > 0 then
                toneRect(edge + fw, y, shadow * 0.45, bh, 0.28, config.dither)
                toneRect(edge + fw + shadow * 0.45, y, shadow * 0.55, bh, 0.10, config.dither)
            end
            if fw > 0 then
                toneRect(edge, y, fw * 0.28, bh, 0.52, config.dither)
                toneRect(edge + fw * 0.28, y, fw * 0.42, bh, 0.12, config.dither)
                toneRect(edge + fw * 0.70, y, fw * 0.30, bh, 0.25, config.dither)
            end
            toneRect(edge, y, 1, bh, 0.72, config.dither)
        else
            local new_w = math.max(0, math.min(dirty_r, edge) - dirty_x)
            if new_w > 0 then Screen.bb:blitFrom(new, dirty_x, y, dirty_x, y, new_w, bh) end
            local old_x = math.max(dirty_x, math.floor(edge))
            local old_w = dirty_r - old_x
            if old_w > 0 then Screen.bb:blitFrom(old, old_x, y, old_x, y, old_w, bh) end

            local fw = math.min(fold_w, edge)
            local fold_x = edge - fw
            local shadow = math.min(shadow_w, fold_x)
            if shadow > 0 then
                local sx = fold_x - shadow
                toneRect(sx, y, shadow * 0.55, bh, 0.10, config.dither)
                toneRect(sx + shadow * 0.55, y, shadow * 0.45, bh, 0.28, config.dither)
            end
            if fw > 0 then
                toneRect(fold_x, y, fw * 0.30, bh, 0.25, config.dither)
                toneRect(fold_x + fw * 0.30, y, fw * 0.42, bh, 0.12, config.dither)
                toneRect(fold_x + fw * 0.72, y, fw * 0.28, bh, 0.52, config.dither)
            end
            toneRect(edge - 1, y, 1, bh, 0.72, config.dither)
        end
        y = y + bh
    end

    return base, dirty_x, dirty_r - dirty_x
end

function ThinCurl.run(old, new, direction, config)
    config = config or {}
    local ready, why = ThinCurl.preflight(config)
    if not ready then error(why) end

    local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()
    local frames = math.max(4, tonumber(config.frames) or 12)
    local scheduler = config.scheduler or "bounded"
    local target_fps = math.max(1, tonumber(config.target_fps) or 20)
    local queue_depth = math.max(1, tonumber(config.queue_depth) or 4)
    local delay_ms = math.max(0, tonumber(config.delay_ms) or 4)
    local period = 1 / target_fps

    Screen.bb:blitFrom(old, 0, 0, 0, 0, sw, sh)
    local started = nowSeconds()
    local logical, submitted, skipped = 1, 0, 0
    local previous_base = direction > 0 and sw or 0
    local markers = {}
    local fallback_outstanding = 0
    local last_marker

    while logical <= frames do
        if scheduler == "fixed" then
            local deadline = started + (logical - 1) * period
            local before = nowSeconds()
            if before < deadline then sleepSeconds(deadline - before)
            else
                local wanted = math.floor((before - started) / period) + 1
                if wanted > logical then
                    wanted = math.min(wanted, frames)
                    skipped = skipped + wanted - logical
                    logical = wanted
                end
            end
        end

        local base, dirty_x, dirty_w = renderFrame(old, new, direction, logical / frames, previous_base, config)
        local marker = submitRefresh(config, dirty_x, 0, dirty_w, sh)
        last_marker = marker or last_marker
        submitted = submitted + 1
        previous_base = base

        if scheduler == "sync" then
            waitMarker(marker)
        elseif scheduler == "bounded" then
            if marker then
                markers[#markers + 1] = marker
                if #markers > queue_depth then waitMarker(table.remove(markers, 1)) end
            else
                fallback_outstanding = fallback_outstanding + 1
                if fallback_outstanding >= queue_depth then
                    if Screen.refreshWaitForLast then Screen:refreshWaitForLast() end
                    fallback_outstanding = 0
                end
            end
            sleepMs(delay_ms)
        elseif scheduler == "free" then
            sleepMs(delay_ms)
        end
        logical = logical + 1
    end

    if scheduler == "bounded" then
        for _, marker in ipairs(markers) do waitMarker(marker) end
        if fallback_outstanding > 0 and Screen.refreshWaitForLast then Screen:refreshWaitForLast() end
    elseif scheduler ~= "sync" then
        waitMarker(last_marker)
    end

    Screen.bb:blitFrom(new, 0, 0, 0, 0, sw, sh)
    return {
        style = "thin_curl",
        elapsed = nowSeconds() - started,
        frames = frames,
        submitted = submitted,
        skipped = skipped,
    }
end

return ThinCurl
