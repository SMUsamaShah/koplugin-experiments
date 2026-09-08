--[[--
E-Ink Motion Lab

Experimental KOReader plugin aimed at Kindle Paperwhite 4 / Rex devices.
It renders a small, smoothly changing "Perlin-like" grayscale field and
tries several refresh paths, including direct MXCFB_SEND_UPDATE_REX calls.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen
local C = ffi.C

local has_mxcfb = pcall(require, "ffi/mxcfb_kindle_h")

local MotionLab = WidgetContainer:extend{
    name = "einkmotionlab",
    is_doc_only = true,
}

local function nowSeconds()
    local s, us = ffiUtil.gettime()
    return s + us / 1000000
end

local function sleepMs(ms)
    if ms and ms > 0 then
        ffiUtil.usleep(ms * 1000)
    end
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function smooth(t)
    return t * t * (3 - 2 * t)
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

-- Fast deterministic integer hash; good enough for visual value noise.
local function hash2(ix, iy, seed)
    local n = (ix * 73856093 + iy * 19349663 + seed * 83492791) % 2147483647
    n = (n * 48271 + 1) % 2147483647
    return n / 2147483647
end

local function valueNoise(x, y, seed)
    local x0 = math.floor(x)
    local y0 = math.floor(y)
    local tx = smooth(x - x0)
    local ty = smooth(y - y0)

    local a = hash2(x0,     y0,     seed)
    local b = hash2(x0 + 1, y0,     seed)
    local c = hash2(x0,     y0 + 1, seed)
    local d = hash2(x0 + 1, y0 + 1, seed)

    return lerp(lerp(a, b, tx), lerp(c, d, tx), ty)
end

local function fractalNoise(x, y)
    return valueNoise(x, y, 11) * 0.55
        + valueNoise(x * 2.03, y * 2.03, 29) * 0.30
        + valueNoise(x * 4.07, y * 4.07, 53) * 0.15
end

local GRAYS = {}
for i = 0, 31 do
    -- Blitbuffer.gray() uses 0 = white, 1 = black.
    GRAYS[i] = Blitbuffer.gray(i / 31)
end

local WHITE = Blitbuffer.gray(0)
local BLACK = Blitbuffer.gray(1)

-- 4x4 Bayer threshold matrix.  With a 2 px render block this produces
-- very fine black/white texture on a 300 dpi PW4 while keeping Lua-side
-- rendering cheap enough to animate.
local BAYER4 = {
     0,  8,  2, 10,
    12,  4, 14,  6,
     3, 11,  1,  9,
    15,  7, 13,  5,
}

local function errnoText()
    return "errno " .. tostring(ffi.errno())
end

local function radioItem(text, checked, callback)
    return {
        text = text,
        radio = true,
        checked_func = checked,
        callback = callback,
    }
end

function MotionLab:onDispatcherRegisterActions()
    Dispatcher:registerAction("einkmotionlab_run_everything", {
        category = "none",
        event = "EInkMotionLabRunEverything",
        title = _("E-Ink Motion Lab: run everything"),
        reader = true,
    })
    Dispatcher:registerAction("einkmotionlab_repeat_last", {
        category = "none",
        event = "EInkMotionLabRepeatLast",
        title = _("E-Ink Motion Lab: repeat last individual test"),
        reader = true,
    })
end

function MotionLab:init()
    self.patch_size = tonumber(G_reader_settings:readSetting("einkmotionlab_patch_size")) or 96
    self.frames = tonumber(G_reader_settings:readSetting("einkmotionlab_frames")) or 24
    self.delay_ms = tonumber(G_reader_settings:readSetting("einkmotionlab_delay_ms")) or 8
    self.block_size = tonumber(G_reader_settings:readSetting("einkmotionlab_block_size")) or 4
    self.bayer_block_size = tonumber(G_reader_settings:readSetting("einkmotionlab_bayer_block_size")) or 2
    self.raw_ok = has_mxcfb and Device:isKindle() and Device:isRex()
        and Screen.fd ~= nil and Screen._get_next_marker ~= nil
    self.results_path = DataStorage:getSettingsDir() .. "/einkmotionlab-last.txt"
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function MotionLab:showInfo(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function MotionLab:setPatchSize(v)
    self.patch_size = v
    G_reader_settings:saveSetting("einkmotionlab_patch_size", v)
end

function MotionLab:setFrames(v)
    self.frames = v
    G_reader_settings:saveSetting("einkmotionlab_frames", v)
end

function MotionLab:setDelay(v)
    self.delay_ms = v
    G_reader_settings:saveSetting("einkmotionlab_delay_ms", v)
end

function MotionLab:setBlockSize(v)
    self.block_size = v
    G_reader_settings:saveSetting("einkmotionlab_block_size", v)
end

function MotionLab:setBayerBlockSize(v)
    self.bayer_block_size = v
    G_reader_settings:saveSetting("einkmotionlab_bayer_block_size", v)
end

function MotionLab:runSafely(label, fn)
    UIManager:nextTick(function()
        local ok, result = pcall(fn)
        if not ok then
            logger.warn("EInkMotionLab " .. label .. " failed:", result)
            self:showInfo("E-Ink Motion Lab: " .. label .. " failed\n\n" .. tostring(result))
        elseif result then
            self:showInfo(result)
        end
    end)
end

function MotionLab:getPatchRect(size)
    local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()
    size = math.floor(math.min(size or self.patch_size, sw - 24, sh - 24))
    local x = math.floor((sw - size) / 2)
    local y = math.floor((sh - size) / 2)
    return x, y, size
end

function MotionLab:paintNoise(x, y, size, phase, block, render_mode)
    block = math.max(1, block or self.block_size)
    render_mode = render_mode or "gray"
    local scale = 3.15
    local drift_x = phase * 0.43
    local drift_y = phase * 0.27

    local yy = 0
    local cy = 0
    while yy < size do
        local bh = math.min(block, size - yy)
        local xx = 0
        local cx = 0
        while xx < size do
            local bw = math.min(block, size - xx)
            local nx = (xx + bw * 0.5) / size * scale + drift_x
            local ny = (yy + bh * 0.5) / size * scale + drift_y
            local v = fractalNoise(nx, ny)

            -- Keep some headroom from absolute white/black so subtle motion
            -- remains visible even on aggressive waveforms.
            v = clamp(0.05 + v * 0.90, 0, 1)

            local color
            if render_mode == "ordered_binary" then
                local bi = (cy % 4) * 4 + (cx % 4) + 1
                local threshold = (BAYER4[bi] + 0.5) / 16
                color = v >= threshold and BLACK or WHITE
            elseif render_mode == "stochastic_binary" then
                -- Static per-cell threshold: noise moves through the pattern,
                -- but the dither mask itself does not sparkle frame-to-frame.
                local threshold = hash2(cx, cy, 97)
                color = v >= threshold and BLACK or WHITE
            else
                local gi = math.floor(v * 31 + 0.5)
                color = GRAYS[gi]
            end

            Screen.bb:paintRect(x + xx, y + yy, bw, bh, color)
            xx = xx + block
            cx = cx + 1
        end
        yy = yy + block
        cy = cy + 1
    end
end

function MotionLab:paintSolid(x, y, w, h, color)
    Screen.bb:paintRect(x, y, w, h, color)
end

function MotionLab:waitMarker(marker)
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

function MotionLab:rawRexUpdate(waveform, x, y, w, h, opts)
    if not self.raw_ok then
        return nil, "Direct Rex ioctl path unavailable"
    end

    opts = opts or {}
    local bb = Screen.full_bb or Screen.bb
    local align = opts.dither_mode and (Screen.dither_alignment_constraint or 8)
        or Screen.alignment_constraint
    x, y, w, h = bb:getBoundedRect(x, y, w, h, align)
    x, y, w, h = bb:getPhysicalRect(x, y, w, h)
    w = w * (Screen.refresh_pixel_size or 1)
    if w <= 1 or h <= 1 then
        return nil, "Region too small"
    end

    if Screen.mech_poweron then
        Screen:mech_poweron()
    end

    local u = ffi.new("struct mxcfb_update_data_rex[1]")
    local d = u[0]
    d.update_region.left = x
    d.update_region.top = y
    d.update_region.width = w
    d.update_region.height = h
    d.waveform_mode = waveform
    d.update_mode = opts.update_mode or C.UPDATE_MODE_PARTIAL
    local marker = Screen:_get_next_marker()
    d.update_marker = marker
    d.temp = C.TEMP_USE_ZELDA_AUTO
    d.flags = opts.flags or 0

    if opts.dither_mode then
        d.dither_mode = opts.dither_mode
        d.quant_bit = opts.quant_bit or 7
    else
        d.dither_mode = C.EPDC_FLAG_USE_DITHERING_PASSTHROUGH
        d.quant_bit = 0
    end

    if waveform == C.WAVEFORM_MODE_ZELDA_GLR16
        or waveform == C.WAVEFORM_MODE_ZELDA_GLD16 then
        d.hist_bw_waveform_mode = waveform
        d.hist_gray_waveform_mode = waveform
    else
        d.hist_bw_waveform_mode = C.WAVEFORM_MODE_DU
        d.hist_gray_waveform_mode = C.WAVEFORM_MODE_GC16
    end

    local ret = C.ioctl(Screen.fd, C.MXCFB_SEND_UPDATE_REX, u)
    if ret == -1 then
        return nil, errnoText()
    end
    return marker
end

function MotionLab:cleanPatch(x, y, size)
    local pad = 8
    local bx = math.max(0, x - pad)
    local by = math.max(0, y - pad)
    local bw = math.min(Screen.bb:getWidth() - bx, size + pad * 2)
    local bh = math.min(Screen.bb:getHeight() - by, size + pad * 2)
    self:paintSolid(bx, by, bw, bh, WHITE)

    if self.raw_ok then
        local marker = self:rawRexUpdate(C.WAVEFORM_MODE_GC16, bx, by, bw, bh, {
            update_mode = C.UPDATE_MODE_FULL,
        })
        self:waitMarker(marker)
    else
        Screen:refreshFull(bx, by, bw, bh)
        if Screen.refreshWaitForLast then Screen:refreshWaitForLast() end
    end
    sleepMs(120)
end

function MotionLab:restorePatch(snapshot, x, y, size)
    if not snapshot then return end
    local pad = 8
    local bx = math.max(0, x - pad)
    local by = math.max(0, y - pad)
    local bw = math.min(Screen.bb:getWidth() - bx, size + pad * 2)
    local bh = math.min(Screen.bb:getHeight() - by, size + pad * 2)
    Screen.bb:blitFrom(snapshot, bx, by, bx, by, bw, bh)
    Screen:refreshFull(bx, by, bw, bh)
    if Screen.refreshWaitForLast then Screen:refreshWaitForLast() end
end

function MotionLab:refreshApi(kind, x, y, size, dither)
    if kind == "a2" then
        Screen:refreshA2(x, y, size, size, dither)
    elseif kind == "fast" then
        Screen:refreshFast(x, y, size, size, dither)
    elseif kind == "ui" then
        Screen:refreshUI(x, y, size, size, dither)
    elseif kind == "partial" then
        Screen:refreshPartial(x, y, size, size, dither)
    else
        error("unknown API refresh kind " .. tostring(kind))
    end
end

function MotionLab:runVisualTest(spec, size, frames)
    local x, y, actual_size = self:getPatchRect(size)
    size = actual_size
    frames = frames or self.frames
    self:cleanPatch(x, y, size)

    local started = nowSeconds()
    local render_seconds = 0
    local last_marker
    local error_text
    local submitted = 0

    for i = 1, frames do
        local render_started = nowSeconds()
        self:paintNoise(x, y, size, (i - 1) * 0.19,
            spec.block_size or self.block_size, spec.render_mode)
        render_seconds = render_seconds + (nowSeconds() - render_started)

        if spec.api then
            self:refreshApi(spec.api, x, y, size, spec.dither == true)
        else
            local marker, err = self:rawRexUpdate(spec.waveform, x, y, size, size, {
                dither_mode = spec.dither_mode,
                quant_bit = spec.quant_bit,
                flags = spec.flags,
                update_mode = spec.update_mode,
            })
            if not marker then
                error_text = err
                break
            end
            last_marker = marker
            if spec.wait_each then
                self:waitMarker(marker)
            end
        end
        submitted = submitted + 1

        if spec.api and spec.wait_each and Screen.refreshWaitForLast then
            Screen:refreshWaitForLast()
        end
        sleepMs(spec.delay_ms ~= nil and spec.delay_ms or self.delay_ms)
    end

    if not error_text then
        if spec.api then
            if Screen.refreshWaitForLast then Screen:refreshWaitForLast() end
        elseif last_marker and not spec.wait_each then
            self:waitMarker(last_marker)
        end
    end

    local elapsed = nowSeconds() - started
    sleepMs(250)

    if error_text then
        return string.format("%s: FAILED after %d frames (%s)",
            spec.name, submitted, error_text)
    end

    local divisor = math.max(1, submitted)
    return string.format(
        "%s: %.0f ms total, %.1f ms/frame wall, %.1f ms/frame render",
        spec.name, elapsed * 1000, elapsed * 1000 / divisor,
        render_seconds * 1000 / divisor)
end

function MotionLab:getVisualTests()
    local common = {
        { name = "KOReader A2 (gray input, no dither)", api = "a2" },
        { name = "KOReader A2 + HW ordered dither", api = "a2", dither = true },
        { name = "KOReader A2 + SW Bayer binary dither", api = "a2",
            render_mode = "ordered_binary", block_size = self.bayer_block_size },
        { name = "KOReader A2 + SW stochastic binary dither", api = "a2",
            render_mode = "stochastic_binary", block_size = 2 },

        { name = "KOReader DU (gray input, no dither)", api = "fast" },
        { name = "KOReader DU + HW ordered dither", api = "fast", dither = true },
        { name = "KOReader DU + SW Bayer binary dither", api = "fast",
            render_mode = "ordered_binary", block_size = self.bayer_block_size },

        { name = "KOReader UI/AUTO", api = "ui" },
    }

    if not self.raw_ok then
        table.insert(common, {
            name = "KOReader Partial synchronized",
            api = "partial", wait_each = true, frames = 4,
        })
        return common
    end

    local raw = {
        { name = "Raw AUTO queued", waveform = C.WAVEFORM_MODE_AUTO },
        { name = "Raw AUTO + ordered dither", waveform = C.WAVEFORM_MODE_AUTO,
            dither_mode = C.EPDC_FLAG_USE_DITHERING_ORDERED, quant_bit = 7 },

        { name = "Raw A2 + ordered dither", waveform = C.WAVEFORM_MODE_ZELDA_A2,
            dither_mode = C.EPDC_FLAG_USE_DITHERING_ORDERED, quant_bit = 1 },
        { name = "Raw A2 + ordered dither (0 ms burst)",
            waveform = C.WAVEFORM_MODE_ZELDA_A2,
            dither_mode = C.EPDC_FLAG_USE_DITHERING_ORDERED, quant_bit = 1,
            delay_ms = 0, frames = 24 },
        { name = "Raw A2 + Floyd-Steinberg", waveform = C.WAVEFORM_MODE_ZELDA_A2,
            dither_mode = C.EPDC_FLAG_USE_DITHERING_FLOYD_STEINBERG, quant_bit = 1 },
        { name = "Raw A2 + Atkinson", waveform = C.WAVEFORM_MODE_ZELDA_A2,
            dither_mode = C.EPDC_FLAG_USE_DITHERING_ATKINSON, quant_bit = 1 },

        { name = "Raw DU + ordered dither", waveform = C.WAVEFORM_MODE_DU,
            dither_mode = C.EPDC_FLAG_USE_DITHERING_ORDERED, quant_bit = 1 },
        { name = "Raw DU + ordered dither (0 ms burst)", waveform = C.WAVEFORM_MODE_DU,
            dither_mode = C.EPDC_FLAG_USE_DITHERING_ORDERED, quant_bit = 1,
            delay_ms = 0, frames = 24 },

        -- The heavier true-gray waveform tests are intentionally short.
        { name = "Raw GC16 queued/no waits", waveform = C.WAVEFORM_MODE_GC16,
            frames = 8 },
        { name = "Raw GC16 synchronized", waveform = C.WAVEFORM_MODE_GC16,
            wait_each = true, frames = 6 },
        { name = "Raw GL16 queued/no waits", waveform = C.WAVEFORM_MODE_ZELDA_GL16,
            frames = 10 },
        { name = "Raw GLR16 PARTIAL queued", waveform = C.WAVEFORM_MODE_ZELDA_GLR16,
            update_mode = C.UPDATE_MODE_PARTIAL, frames = 8 },
        { name = "Raw GLD16 PARTIAL + ordered", waveform = C.WAVEFORM_MODE_ZELDA_GLD16,
            update_mode = C.UPDATE_MODE_PARTIAL,
            dither_mode = C.EPDC_FLAG_USE_DITHERING_ORDERED, quant_bit = 7,
            flags = C.EPDC_FLAG_USE_ZELDA_REGAL, frames = 8 },

        -- This intentionally goes through KOReader's conservative REAGL path.
        { name = "KOReader Partial/REAGL synchronized", api = "partial",
            wait_each = true, frames = 4 },
    }

    for _, spec in ipairs(raw) do
        table.insert(common, spec)
    end
    return common
end

function MotionLab:writeResults(lines)
    local f = io.open(self.results_path, "w")
    if f then
        f:write(table.concat(lines, "\n"))
        f:write("\n")
        f:close()
    end
end

function MotionLab:capabilityLines()
    local lines = {
        "E-Ink Motion Lab capability probe",
        "Device model: " .. tostring(Device.model or "unknown"),
        "Kindle: " .. tostring(Device:isKindle()),
        "Rex: " .. tostring(Device:isRex()),
        "Direct Rex ioctl path: " .. tostring(self.raw_ok),
        "Framebuffer bpp: " .. tostring(Screen.bb:getBpp()),
        "Night mode: " .. tostring(Screen.night_mode == true),
        "Configured patch: " .. tostring(self.patch_size) .. "x" .. tostring(self.patch_size),
    }

    if self.raw_ok then
        local wf = ffi.new("uint32_t[1]", 0)
        local ret = C.ioctl(Screen.fd, C.MXCFB_GET_WAVEFORM_TYPE, wf)
        if ret == 0 then
            local v = tonumber(wf[0])
            local desc = "unknown"
            if v == C.WAVEFORM_TYPE_4BIT then desc = "4-bit / 16 physical target levels"
            elseif v == C.WAVEFORM_TYPE_5BIT then desc = "5-bit / 32 physical target levels"
            end
            table.insert(lines, "Waveform type: " .. tostring(v) .. " (" .. desc .. ")")
        else
            table.insert(lines, "Waveform type ioctl: FAILED (" .. errnoText() .. ")")
        end

        local temp = ffi.new("int32_t[1]", 0)
        ret = C.ioctl(Screen.fd, C.MXCFB_GET_TEMPERATURE, temp)
        if ret == 0 then
            table.insert(lines, "EPDC temperature: " .. tostring(tonumber(temp[0])) .. " C")
        else
            table.insert(lines, "Temperature ioctl: FAILED (" .. errnoText() .. ")")
        end
    end

    return lines
end

function MotionLab:runMotionSuite()
    local snapshot = Screen.bb:copy()
    local x, y, size = self:getPatchRect(self.patch_size)
    local lines = self:capabilityLines()
    table.insert(lines, "")
    table.insert(lines, "Visual motion suite (" .. size .. "x" .. size .. "):")

    local tests = self:getVisualTests()
    for _, spec in ipairs(tests) do
        local frames = spec.frames or self.frames
        local ok, result = pcall(function()
            return self:runVisualTest(spec, size, frames)
        end)
        if ok then
            table.insert(lines, result)
        else
            table.insert(lines, spec.name .. ": ERROR " .. tostring(result))
        end
        self:writeResults(lines)
    end

    self:restorePatch(snapshot, x, y, size)
    snapshot:free()
    UIManager:setDirty(self.ui, "ui")
    self:writeResults(lines)

    return table.concat(lines, "\n")
end

function MotionLab:runSizeSweep()
    local snapshot = Screen.bb:copy()
    local lines = {
        "E-Ink Motion Lab size sweep",
        "12 frames per size; same noise animation.",
        "",
    }

    local specs = {
        { name = "A2+ordered", api = "a2", dither = true },
        { name = "DU+ordered", api = "fast", dither = true },
    }
    if self.raw_ok then
        table.insert(specs, {
            name = "Raw AUTO",
            waveform = C.WAVEFORM_MODE_AUTO,
        })
    end

    local sizes = { 32, 64, 96, 128, 192 }
    for _, spec in ipairs(specs) do
        table.insert(lines, spec.name .. ":")
        for _, size in ipairs(sizes) do
            local x, y, actual = self:getPatchRect(size)
            local started = nowSeconds()
            local result = self:runVisualTest(spec, actual, 12)
            local elapsed = (nowSeconds() - started) * 1000
            table.insert(lines, string.format("  %dx%d -> %.0f ms wall (%s)",
                actual, actual, elapsed, result))
            self:restorePatch(snapshot, x, y, actual)
        end
        table.insert(lines, "")
        self:writeResults(lines)
    end

    snapshot:free()
    UIManager:setDirty(self.ui, "ui")
    self:writeResults(lines)
    return table.concat(lines, "\n")
end

function MotionLab:pauseTrial(delay_ms, hold_ms)
    local lines = {
        string.format("GC16 pause trial: delay=%d ms, hold=%d ms", delay_ms, hold_ms),
    }

    if not self.raw_ok then
        table.insert(lines, "Skipped: requires Kindle Rex direct ioctl path.")
        return lines, false, false
    end

    local snapshot = Screen.bb:copy()
    local x, y, size = self:getPatchRect(self.patch_size)
    self:cleanPatch(x, y, size)

    -- Start with a clean white patch, then ask GC16 to take it to black.
    self:paintSolid(x, y, size, size, BLACK)
    local marker, err = self:rawRexUpdate(C.WAVEFORM_MODE_GC16, x, y, size, size, {
        update_mode = C.UPDATE_MODE_PARTIAL,
    })
    if not marker then
        table.insert(lines, "GC16 submit failed: " .. tostring(err))
        self:restorePatch(snapshot, x, y, size)
        snapshot:free()
        return lines, false, false
    end

    sleepMs(delay_ms)

    -- The public Kindle header declares these as uint32_t ioctls but does not
    -- document their semantics. Pass the active marker: if it is marker-based
    -- that is what we want; if SET_PAUSE is boolean-like it is still non-zero.
    local arg = ffi.new("uint32_t[1]", marker)
    local pause_ret = C.ioctl(Screen.fd, C.MXCFB_SET_PAUSE, arg)
    local pause_errno = pause_ret == -1 and ffi.errno() or 0
    local pause_supported = pause_ret == 0
    table.insert(lines, "SET_PAUSE: " .. tostring(pause_ret)
        .. (pause_ret == -1 and (" (errno " .. tostring(pause_errno) .. ")") or ""))

    local getarg = ffi.new("uint32_t[1]", 0)
    local get_ret = C.ioctl(Screen.fd, C.MXCFB_GET_PAUSE, getarg)
    table.insert(lines, "GET_PAUSE: " .. tostring(get_ret)
        .. ", value=" .. tostring(tonumber(getarg[0]))
        .. (get_ret == -1 and (" (" .. errnoText() .. ")") or ""))

    local safe_to_wait = true
    if pause_ret == 0 then
        -- This hold is deliberately long enough that a successful pause should
        -- be obvious to the eye or on a phone video.
        sleepMs(hold_ms)

        local resume_arg = ffi.new("uint32_t[1]", marker)
        local resume_ret = C.ioctl(Screen.fd, C.MXCFB_SET_RESUME, resume_arg)
        table.insert(lines, "SET_RESUME: " .. tostring(resume_ret)
            .. (resume_ret == -1 and (" (" .. errnoText() .. ")") or ""))

        if resume_ret == -1 then
            -- Fallback in case SET_PAUSE itself is a simple on/off control.
            local zero = ffi.new("uint32_t[1]", 0)
            local clear_ret = C.ioctl(Screen.fd, C.MXCFB_SET_PAUSE, zero)
            table.insert(lines, "SET_PAUSE(0) fallback: " .. tostring(clear_ret)
                .. (clear_ret == -1 and (" (" .. errnoText() .. ")") or ""))
            if clear_ret == -1 then
                safe_to_wait = false
                table.insert(lines,
                    "WARNING: resume and fallback both failed; not waiting on the marker.")
            end
        end
    end

    if safe_to_wait then
        self:waitMarker(marker)
        sleepMs(180)
        self:restorePatch(snapshot, x, y, size)
    else
        -- Put the logical framebuffer back even if the EPDC may still be
        -- paused. Avoid issuing another display update that could block.
        local pad = 8
        local bx = math.max(0, x - pad)
        local by = math.max(0, y - pad)
        local bw = math.min(Screen.bb:getWidth() - bx, size + pad * 2)
        local bh = math.min(Screen.bb:getHeight() - by, size + pad * 2)
        Screen.bb:blitFrom(snapshot, bx, by, bx, by, bw, bh)
    end
    snapshot:free()

    table.insert(lines, "Visual check: did the square hold an intermediate gray?")
    return lines, safe_to_wait, pause_supported
end

function MotionLab:pauseProbe()
    local lines, safe = self:pauseTrial(80, 700)
    table.insert(lines, "")
    if safe then
        table.insert(lines, "If it visibly froze during the 700 ms hold,")
        table.insert(lines, "the pause ioctl is useful for waveform-frame experiments.")
    else
        table.insert(lines, "The display path may still be paused; restart KOReader if needed.")
    end
    self:writeResults(lines)
    if safe then UIManager:setDirty(self.ui, "ui") end
    return table.concat(lines, "\n")
end

function MotionLab:pauseTimingSweep()
    local lines = {
        "GC16 pause timing sweep",
        "Each trial starts from clean white and targets black.",
        "If pause works, compare the held shade at each delay.",
        "",
    }

    if not self.raw_ok then
        table.insert(lines, "Skipped: requires Kindle Rex direct ioctl path.")
        return table.concat(lines, "\n")
    end

    for _, delay in ipairs({ 20, 40, 60, 80, 100, 140 }) do
        local trial, safe, supported = self:pauseTrial(delay, 450)
        for _, line in ipairs(trial) do table.insert(lines, line) end
        table.insert(lines, "")
        self:writeResults(lines)

        if not supported then
            table.insert(lines, "Stopped sweep: SET_PAUSE is not supported by this driver.")
            break
        end
        if not safe then
            table.insert(lines, "Stopped sweep because resume could not be confirmed.")
            break
        end
        sleepMs(250)
    end

    UIManager:setDirty(self.ui, "ui")
    self:writeResults(lines)
    return table.concat(lines, "\n")
end

function MotionLab:runEverything()
    local lines = self:capabilityLines()
    table.insert(lines, "")
    table.insert(lines, "=== MOTION SUITE ===")

    local snapshot = Screen.bb:copy()
    local x, y, size = self:getPatchRect(self.patch_size)
    local tests = self:getVisualTests()

    for _, spec in ipairs(tests) do
        local frames = spec.frames or self.frames
        local ok, result = pcall(function()
            return self:runVisualTest(spec, size, frames)
        end)
        table.insert(lines, ok and result or (spec.name .. ": ERROR " .. tostring(result)))
        self:writeResults(lines)
    end

    self:restorePatch(snapshot, x, y, size)

    table.insert(lines, "")
    table.insert(lines, "=== SHORT SIZE SWEEP ===")
    local sweep_specs = {
        { name = "A2+ordered", api = "a2", dither = true },
        { name = "DU+ordered", api = "fast", dither = true },
    }
    if self.raw_ok then
        table.insert(sweep_specs, { name = "Raw AUTO", waveform = C.WAVEFORM_MODE_AUTO })
    end

    for _, spec in ipairs(sweep_specs) do
        for _, req_size in ipairs({ 32, 64, 128 }) do
            local sx, sy, actual = self:getPatchRect(req_size)
            local started = nowSeconds()
            local ok, result = pcall(function()
                return self:runVisualTest(spec, actual, 8)
            end)
            local ms = (nowSeconds() - started) * 1000
            table.insert(lines, string.format("%s %dx%d: %.0f ms%s",
                spec.name, actual, actual, ms,
                ok and "" or (" ERROR " .. tostring(result))))
            self:restorePatch(snapshot, sx, sy, actual)
            self:writeResults(lines)
        end
    end

    if self.raw_ok then
        table.insert(lines, "")
        table.insert(lines, "=== GC16 PAUSE IOCTL PROBE (LAST TEST) ===")
        self:writeResults(lines)
        local trial, safe = self:pauseTrial(80, 700)
        for _, line in ipairs(trial) do table.insert(lines, line) end
        if not safe then
            table.insert(lines,
                "Pause resume was not confirmed; restart KOReader if the display remains stuck.")
        end
    end

    snapshot:free()
    UIManager:setDirty(self.ui, "ui")
    self:writeResults(lines)

    table.insert(lines, "")
    table.insert(lines, "Results saved to:")
    table.insert(lines, self.results_path)
    return table.concat(lines, "\n")
end

function MotionLab:capabilityReport()
    local lines = self:capabilityLines()
    self:writeResults(lines)
    return table.concat(lines, "\n")
end

function MotionLab:repeatLastIndividualTest()
    local wanted = G_reader_settings:readSetting("einkmotionlab_last_test")
    if not wanted then
        return "No individual test has been run yet. Run one once from the Motion Lab menu."
    end

    for _, test in ipairs(self:getVisualTests()) do
        if test.name == wanted then
            local snapshot = Screen.bb:copy()
            local x, y, size = self:getPatchRect(self.patch_size)
            local result = self:runVisualTest(test, size, test.frames or self.frames)
            self:restorePatch(snapshot, x, y, size)
            snapshot:free()
            UIManager:setDirty(self.ui, "ui")
            return "Repeated: " .. result
        end
    end

    return "The previously selected test is no longer available: " .. tostring(wanted)
end

function MotionLab:onEInkMotionLabRunEverything()
    self:runSafely("everything", function() return self:runEverything() end)
end

function MotionLab:onEInkMotionLabRepeatLast()
    self:runSafely("repeat last test", function() return self:repeatLastIndividualTest() end)
end

function MotionLab:individualItems()
    local items = {}
    for _, spec in ipairs(self:getVisualTests()) do
        local test = spec
        table.insert(items, {
            text = test.name,
            keep_menu_open = true,
            callback = function()
                G_reader_settings:saveSetting("einkmotionlab_last_test", test.name)
                self:runSafely(test.name, function()
                    local snapshot = Screen.bb:copy()
                    local x, y, size = self:getPatchRect(self.patch_size)
                    local result = self:runVisualTest(test, size, test.frames or self.frames)
                    self:restorePatch(snapshot, x, y, size)
                    snapshot:free()
                    UIManager:setDirty(self.ui, "ui")
                    return result
                end)
            end,
        })
    end
    return items
end

function MotionLab:addToMainMenu(menu_items)
    menu_items.einkmotionlab = {
        text = _("E-Ink Motion / Grayscale Lab"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Run EVERYTHING (recommended first test)"),
                callback = function()
                    self:runSafely("everything", function() return self:runEverything() end)
                end,
            },
            {
                text = _("Repeat last individual test"),
                callback = function()
                    self:runSafely("repeat last test",
                        function() return self:repeatLastIndividualTest() end)
                end,
            },
            {
                text = _("Run Perlin-like motion suite"),
                callback = function()
                    self:runSafely("motion suite", function() return self:runMotionSuite() end)
                end,
            },
            {
                text = _("Run patch-size sweep"),
                callback = function()
                    self:runSafely("size sweep", function() return self:runSizeSweep() end)
                end,
            },
            {
                text = _("Probe GC16 pause/resume ioctl (80 ms)"),
                callback = function()
                    self:runSafely("pause probe", function() return self:pauseProbe() end)
                end,
            },
            {
                text = _("GC16 pause timing sweep (20..140 ms)"),
                callback = function()
                    self:runSafely("pause timing sweep",
                        function() return self:pauseTimingSweep() end)
                end,
            },
            {
                text = _("Show PW4 / waveform capabilities"),
                callback = function()
                    self:runSafely("capabilities", function() return self:capabilityReport() end)
                end,
            },
            {
                text = _("Run one test"),
                sub_item_table = self:individualItems(),
            },
            {
                text = _("Patch size"),
                sub_item_table = {
                    radioItem("32 x 32", function() return self.patch_size == 32 end,
                        function() self:setPatchSize(32) end),
                    radioItem("64 x 64", function() return self.patch_size == 64 end,
                        function() self:setPatchSize(64) end),
                    radioItem("96 x 96", function() return self.patch_size == 96 end,
                        function() self:setPatchSize(96) end),
                    radioItem("128 x 128", function() return self.patch_size == 128 end,
                        function() self:setPatchSize(128) end),
                    radioItem("192 x 192", function() return self.patch_size == 192 end,
                        function() self:setPatchSize(192) end),
                    radioItem("256 x 256", function() return self.patch_size == 256 end,
                        function() self:setPatchSize(256) end),
                    radioItem("384 x 384", function() return self.patch_size == 384 end,
                        function() self:setPatchSize(384) end),
                    radioItem("512 x 512", function() return self.patch_size == 512 end,
                        function() self:setPatchSize(512) end),
                    radioItem("768 x 768", function() return self.patch_size == 768 end,
                        function() self:setPatchSize(768) end),
                    radioItem("1024 x 1024", function() return self.patch_size == 1024 end,
                        function() self:setPatchSize(1024) end),
                },
            },
            {
                text = _("Frames per visual test"),
                sub_item_table = {
                    radioItem("12", function() return self.frames == 12 end,
                        function() self:setFrames(12) end),
                    radioItem("24", function() return self.frames == 24 end,
                        function() self:setFrames(24) end),
                    radioItem("36", function() return self.frames == 36 end,
                        function() self:setFrames(36) end),
                    radioItem("48", function() return self.frames == 48 end,
                        function() self:setFrames(48) end),
                    radioItem("60", function() return self.frames == 60 end,
                        function() self:setFrames(60) end),
                    radioItem("120", function() return self.frames == 120 end,
                        function() self:setFrames(120) end),
                    radioItem("240", function() return self.frames == 240 end,
                        function() self:setFrames(240) end),
                    radioItem("480", function() return self.frames == 480 end,
                        function() self:setFrames(480) end),
                    radioItem("960", function() return self.frames == 960 end,
                        function() self:setFrames(960) end),
                },
            },
            {
                text = _("Delay between submitted frames"),
                sub_item_table = {
                    radioItem("0 ms", function() return self.delay_ms == 0 end,
                        function() self:setDelay(0) end),
                    radioItem("4 ms", function() return self.delay_ms == 4 end,
                        function() self:setDelay(4) end),
                    radioItem("8 ms", function() return self.delay_ms == 8 end,
                        function() self:setDelay(8) end),
                    radioItem("16 ms", function() return self.delay_ms == 16 end,
                        function() self:setDelay(16) end),
                    radioItem("25 ms", function() return self.delay_ms == 25 end,
                        function() self:setDelay(25) end),
                },
            },
            {
                text = _("SW Bayer block size"),
                sub_item_table = {
                    radioItem("2 px (best-looking, most CPU)", function() return self.bayer_block_size == 2 end,
                        function() self:setBayerBlockSize(2) end),
                    radioItem("4 px (faster for large patches)", function() return self.bayer_block_size == 4 end,
                        function() self:setBayerBlockSize(4) end),
                    radioItem("8 px (stress large display regions)", function() return self.bayer_block_size == 8 end,
                        function() self:setBayerBlockSize(8) end),
                    radioItem("16 px (minimize Lua render cost)", function() return self.bayer_block_size == 16 end,
                        function() self:setBayerBlockSize(16) end),
                },
            },
            {
                text = _("Noise render block size"),
                sub_item_table = {
                    radioItem("2 px (smoothest, more CPU)", function() return self.block_size == 2 end,
                        function() self:setBlockSize(2) end),
                    radioItem("4 px", function() return self.block_size == 4 end,
                        function() self:setBlockSize(4) end),
                    radioItem("8 px (fastest CPU)", function() return self.block_size == 8 end,
                        function() self:setBlockSize(8) end),
                },
            },
        },
    }
end

return MotionLab
