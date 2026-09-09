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
local bit = require("bit")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")
local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local diagnostic_path = plugin_dir .. "renderdiagnostic.lua"

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

-- The original large-product hash became slower at later noise coordinates
-- on PW4, even in an off-screen CPU-only test. Use the bit-operation hash
-- that maintained consistent timing in that device test.
local function hash2(ix, iy, seed)
    local h = bit.bxor(bit.tobit(ix), bit.rol(bit.tobit(iy), 16),
        bit.rol(bit.tobit(seed), 8), 0x9e3779b9)
    h = bit.bxor(h, bit.lshift(h, 13))
    h = bit.bxor(h, bit.rshift(h, 17))
    h = bit.bxor(h, bit.lshift(h, 5))
    h = bit.tobit(h + bit.lshift(h, 10))
    h = bit.bxor(h, bit.rshift(h, 6))
    h = bit.tobit(h + bit.lshift(h, 3))
    h = bit.bxor(h, bit.rshift(h, 11))
    h = bit.tobit(h + bit.lshift(h, 15))
    return bit.band(h, 0x7fffffff) / 2147483647
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

local function readTextFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local value = f:read("*a")
    f:close()
    if not value then return nil end
    value = value:gsub("%s+$", "")
    if value == "" then return nil end
    return value
end

local function firstReadable(paths)
    for _, path in ipairs(paths) do
        local value = readTextFile(path)
        if value then return value end
    end
    return nil
end

local function firstReadableWithPath(paths)
    for _, path in ipairs(paths) do
        local value = readTextFile(path)
        if value then return value, path end
    end
    return nil, nil
end

local function formatFreq(khz)
    if not khz then return "n/a" end
    return string.format("%.0f MHz", khz / 1000)
end

local function formatTemp(c)
    if not c then return "n/a" end
    return string.format("%.1f C", c)
end

function MotionLab:readSystemState()
    local freq_raw, freq_path = firstReadableWithPath({
        "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq",
        "/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_cur_freq",
        "/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq",
        "/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_cur_freq",
    })
    local freq = tonumber(freq_raw)
    if freq_path then self._telemetry_freq_path = freq_path end
    local min_freq = tonumber(firstReadable({
        "/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq",
        "/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq",
    }))
    local max_freq = tonumber(firstReadable({
        "/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq",
        "/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq",
    }))
    local governor = firstReadable({
        "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor",
        "/sys/devices/system/cpu/cpufreq/policy0/scaling_governor",
    })

    local hottest
    local hottest_path
    local zones = {}
    for i = 0, 9 do
        local path = string.format("/sys/class/thermal/thermal_zone%d/temp", i)
        local raw = readTextFile(path)
        local n = tonumber(raw)
        if n then
            if math.abs(n) > 1000 then n = n / 1000 end
            zones[#zones + 1] = string.format("tz%d=%.1fC", i, n)
            if not hottest or n > hottest then
                hottest = n
                hottest_path = path
            end
        end
    end
    for i = 0, 3 do
        local path = string.format("/sys/class/hwmon/hwmon%d/temp1_input", i)
        local raw = readTextFile(path)
        local n = tonumber(raw)
        if n then
            if math.abs(n) > 1000 then n = n / 1000 end
            zones[#zones + 1] = string.format("hwmon%d=%.1fC", i, n)
            if not hottest or n > hottest then
                hottest = n
                hottest_path = path
            end
        end
    end
    if hottest_path then self._telemetry_temp_path = hottest_path end

    local loadavg = readTextFile("/proc/loadavg")
    local meminfo = readTextFile("/proc/meminfo") or ""
    local mem_kb = tonumber(meminfo:match("MemAvailable:%s+(%d+)%s+kB"))
        or tonumber(meminfo:match("MemFree:%s+(%d+)%s+kB"))

    return {
        freq_khz = freq,
        min_freq_khz = min_freq,
        max_freq_khz = max_freq,
        governor = governor,
        temp_c = hottest,
        thermal = #zones > 0 and table.concat(zones, ", ") or "n/a",
        loadavg = loadavg or "n/a",
        mem_mb = mem_kb and (mem_kb / 1024) or nil,
    }
end

function MotionLab:readTelemetryState()
    -- During animation, sample CPU frequency only. Temperature changes much
    -- more slowly and is captured by the full system snapshots immediately
    -- before and after the timed animation, avoiding unnecessary sysfs reads.
    local freq_raw
    if self._telemetry_freq_path then
        freq_raw = readTextFile(self._telemetry_freq_path)
    else
        freq_raw = firstReadable({
            "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq",
            "/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq",
        })
    end

    return {
        freq_khz = tonumber(freq_raw),
    }
end

function MotionLab:telemetryStateText(state)
    state = state or {}
    return string.format("cpu=%s", formatFreq(state.freq_khz))
end

function MotionLab:systemStateText(state)
    state = state or {}
    return string.format(
        "cpu=%s min=%s max=%s governor=%s temp=%s thermal=[%s] load=[%s] mem_avail=%s",
        formatFreq(state.freq_khz), formatFreq(state.min_freq_khz),
        formatFreq(state.max_freq_khz), tostring(state.governor or "n/a"),
        formatTemp(state.temp_c), tostring(state.thermal or "n/a"),
        tostring(state.loadavg or "n/a"),
        state.mem_mb and string.format("%.1f MB", state.mem_mb) or "n/a")
end

function MotionLab:appendLog(lines)
    local f = io.open(self.log_path, "a")
    if not f then return end
    for _, line in ipairs(lines) do
        f:write(tostring(line), "\n")
    end
    f:write("\n")
    f:close()
end

function MotionLab:currentSettingsLines(spec, actual_size, run_frames, scheduler)
    spec = spec or {}
    local render_block = self:isBayerMotionTest(spec) and self.bayer_block_size
        or (spec.block_size or self.block_size)
    return {
        "plugin_version=0.1.11",
        "noise_hash=bounded_bit_hash",
        "configured_patch_size=" .. tostring(self.patch_size),
        "actual_patch_size=" .. tostring(actual_size or self.patch_size),
        "configured_frames=" .. tostring(self.frames),
        "run_frames=" .. tostring(run_frames or self.frames),
        "delay_ms=" .. tostring(self.delay_ms),
        "noise_render_block_px=" .. tostring(self.block_size),
        "sw_bayer_block_px=" .. tostring(self.bayer_block_size),
        "effective_render_block_px=" .. tostring(render_block),
        "scheduler=" .. tostring(scheduler or self.scheduler_mode),
        "target_fps=" .. tostring(self.target_fps),
        "queue_depth=" .. tostring(self.queue_depth),
        "night_mode=" .. tostring(Screen.night_mode == true),
        "screen=" .. tostring(Screen.bb:getWidth()) .. "x" .. tostring(Screen.bb:getHeight()),
        "framebuffer_bpp=" .. tostring(Screen.bb:getBpp()),
        "raw_rex_available=" .. tostring(self.raw_ok),
        "test_api=" .. tostring(spec.api or "raw"),
        "test_waveform=" .. tostring(spec.waveform or "n/a"),
        "test_render_mode=" .. tostring(spec.render_mode or "gray"),
        "test_hw_dither=" .. tostring(spec.dither == true),
        "test_dither_mode=" .. tostring(spec.dither_mode or "n/a"),
        "test_wait_each=" .. tostring(spec.wait_each == true),
        "test_delay_override_ms=" .. tostring(spec.delay_ms ~= nil and spec.delay_ms or "none"),
    }
end

function MotionLab:captureTelemetry(submitted, logical, row)
    local started = nowSeconds()
    local state = self:readTelemetryState()
    return {
        submitted = submitted,
        logical = logical,
        row = row,
        state = state,
        probe_ms = (nowSeconds() - started) * 1000,
    }
end

function MotionLab:appendRunLog(spec, actual_size, run_frames, scheduler,
        summary, timing, telemetry, start_state, end_state, submitted, skipped)
    local lines = {
        "================================================================",
        "RUN " .. os.date("%Y-%m-%d %H:%M:%S"),
        "test=" .. tostring(spec.name or "unknown"),
        "-- SETTINGS --",
    }
    for _, line in ipairs(self:currentSettingsLines(spec, actual_size, run_frames, scheduler)) do
        lines[#lines + 1] = line
    end
    lines[#lines + 1] = "submitted_frames=" .. tostring(submitted or 0)
    lines[#lines + 1] = "skipped_logical_frames=" .. tostring(skipped or 0)
    lines[#lines + 1] = "-- SYSTEM START --"
    lines[#lines + 1] = self:systemStateText(start_state)
    lines[#lines + 1] = "-- CPU FREQUENCY SAMPLES (first, every 10 submitted frames, last) --"
    if telemetry and #telemetry > 0 then
        for _, sample in ipairs(telemetry) do
            local r = sample.row or {}
            lines[#lines + 1] = string.format(
                "submitted=%d logical=%d render=%.1fms refresh=%.1fms wait=%.1fms sleep=%.1fms interval=%.1fms late=%.1fms probe=%.2fms | %s",
                sample.submitted or 0, sample.logical or 0,
                r.render_ms or 0, r.refresh_ms or 0, r.wait_ms or 0,
                r.sleep_ms or 0, r.interval_ms or 0, r.lateness_ms or 0,
                sample.probe_ms or 0, self:telemetryStateText(sample.state))
        end
    else
        lines[#lines + 1] = "none"
    end
    lines[#lines + 1] = "-- RESULT --"
    lines[#lines + 1] = tostring(summary)
    lines[#lines + 1] = tostring(timing or "")
    lines[#lines + 1] = "-- SYSTEM END --"
    lines[#lines + 1] = self:systemStateText(end_state)
    self:appendLog(lines)
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
    self.scheduler_mode = G_reader_settings:readSetting("einkmotionlab_scheduler_mode") or "free"
    self.target_fps = tonumber(G_reader_settings:readSetting("einkmotionlab_target_fps")) or 60
    self.queue_depth = tonumber(G_reader_settings:readSetting("einkmotionlab_queue_depth")) or 4
    self.gif_mode = G_reader_settings:readSetting("einkmotionlab_gif_mode") or "a2"
    self.gif_clock = G_reader_settings:readSetting("einkmotionlab_gif_clock") or "original"
    self.gif_loops = math.max(1, math.min(10,
        tonumber(G_reader_settings:readSetting("einkmotionlab_gif_loops")) or 3))
    self.raw_ok = has_mxcfb and Device:isKindle() and Device:isRex()
        and Screen.fd ~= nil and Screen._get_next_marker ~= nil
    self.log_path = DataStorage:getSettingsDir() .. "/einkmotionlab.log"
    self.results_path = self.log_path
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

function MotionLab:setSchedulerMode(v)
    self.scheduler_mode = v
    G_reader_settings:saveSetting("einkmotionlab_scheduler_mode", v)
end

function MotionLab:setTargetFps(v)
    self.target_fps = v
    G_reader_settings:saveSetting("einkmotionlab_target_fps", v)
end

function MotionLab:setQueueDepth(v)
    self.queue_depth = v
    G_reader_settings:saveSetting("einkmotionlab_queue_depth", v)
end

function MotionLab:runSafely(label, fn)
    UIManager:nextTick(function()
        local ok, result = pcall(fn)
        if not ok then
            logger.warn("EInkMotionLab " .. label .. " failed:", result)
            local lines = {
                "================================================================",
                "ERROR " .. os.date("%Y-%m-%d %H:%M:%S"),
                "operation=" .. tostring(label),
                "message=" .. tostring(result),
                "-- SETTINGS --",
            }
            for _, line in ipairs(self:currentSettingsLines()) do lines[#lines + 1] = line end
            lines[#lines + 1] = "-- SYSTEM --"
            lines[#lines + 1] = self:systemStateText(self:readSystemState())
            self:appendLog(lines)
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

function MotionLab:isBayerMotionTest(spec)
    return spec.render_mode == "ordered_binary"
        and (spec.api == "a2" or spec.api == "fast")
end

local function avgMetric(rows, first, last, key)
    local total, count = 0, 0
    for i = first, last do
        local v = rows[i] and rows[i][key]
        if v and (key ~= "interval_ms" or v > 0) then
            total = total + v
            count = count + 1
        end
    end
    if count == 0 then return 0 end
    return total / count
end

function MotionLab:timingSummary(rows)
    local n = #rows
    if n == 0 then return "no frame timings" end
    local span = math.max(1, math.floor(n * 0.20 + 0.5))
    local mid_first = math.max(1, math.floor((n - span) / 2) + 1)
    local mid_last = math.min(n, mid_first + span - 1)
    local last_first = math.max(1, n - span + 1)

    local function triplet(key)
        return avgMetric(rows, 1, span, key),
            avgMetric(rows, mid_first, mid_last, key),
            avgMetric(rows, last_first, n, key)
    end

    local r1, r2, r3 = triplet("render_ms")
    local u1, u2, u3 = triplet("refresh_ms")
    local w1, w2, w3 = triplet("wait_ms")
    local i1, i2, i3 = triplet("interval_ms")
    return string.format(
        "early/mid/late ms: render %.1f/%.1f/%.1f, refresh %.1f/%.1f/%.1f, wait %.1f/%.1f/%.1f, interval %.1f/%.1f/%.1f",
        r1, r2, r3, u1, u2, u3, w1, w2, w3, i1, i2, i3)
end

function MotionLab:runVisualTest(spec, size, frames)
    local x, y, actual_size = self:getPatchRect(size)
    size = actual_size
    frames = frames or self.frames
    self:cleanPatch(x, y, size)

    local start_state = self:readSystemState()
    local telemetry = {}
    local bayer_motion = self:isBayerMotionTest(spec)
    local scheduler = bayer_motion and self.scheduler_mode or "legacy"
    local period = 1 / math.max(1, self.target_fps)
    local configured_delay = spec.delay_ms ~= nil and spec.delay_ms or self.delay_ms

    local started = nowSeconds()
    local render_seconds = 0
    local refresh_seconds = 0
    local wait_seconds = 0
    local sleep_seconds = 0
    local last_marker
    local error_text
    local submitted = 0
    local logical = 1
    local skipped_total = 0
    local previous_frame_started
    local marker_queue = {}
    local rows = {}

    while logical <= frames do
        local skipped_before = 0
        local sleep_this = 0
        local deadline = started

        if scheduler == "fixed" then
            deadline = started + (logical - 1) * period
            local before = nowSeconds()
            if before < deadline then
                local us = math.floor((deadline - before) * 1000000)
                if us > 0 then
                    ffiUtil.usleep(us)
                    sleep_this = us / 1000000
                    sleep_seconds = sleep_seconds + sleep_this
                end
            else
                local wanted = math.floor((before - started) / period) + 1
                if wanted > logical then
                    wanted = math.min(wanted, frames)
                    skipped_before = wanted - logical
                    skipped_total = skipped_total + skipped_before
                    logical = wanted
                    deadline = started + (logical - 1) * period
                end
            end
        end

        local frame_started = nowSeconds()
        local interval_ms = previous_frame_started and ((frame_started - previous_frame_started) * 1000) or 0
        previous_frame_started = frame_started
        local lateness_ms = scheduler == "fixed" and math.max(0, (frame_started - deadline) * 1000) or 0

        local render_started = nowSeconds()
        -- Read the Bayer block size at execution time, not when the menu was built.
        local render_block = bayer_motion and self.bayer_block_size
            or (spec.block_size or self.block_size)
        self:paintNoise(x, y, size, (logical - 1) * 0.19,
            render_block, spec.render_mode)
        local render_elapsed = nowSeconds() - render_started
        render_seconds = render_seconds + render_elapsed

        local refresh_started = nowSeconds()
        local marker_for_frame
        if spec.api then
            local marker_before = Screen.marker
            self:refreshApi(spec.api, x, y, size, spec.dither == true)
            if Screen.marker and Screen.marker ~= marker_before then
                marker_for_frame = Screen.marker
            end
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
            marker_for_frame = marker
            last_marker = marker
        end
        local refresh_elapsed = nowSeconds() - refresh_started
        refresh_seconds = refresh_seconds + refresh_elapsed
        submitted = submitted + 1

        local wait_this = 0
        if spec.wait_each then
            local wait_started = nowSeconds()
            if spec.api and Screen.refreshWaitForLast then
                Screen:refreshWaitForLast()
            elseif marker_for_frame then
                self:waitMarker(marker_for_frame)
            end
            wait_this = nowSeconds() - wait_started
        elseif scheduler == "bounded" and marker_for_frame then
            table.insert(marker_queue, marker_for_frame)
            if #marker_queue > math.max(1, self.queue_depth) then
                local oldest = table.remove(marker_queue, 1)
                local wait_started = nowSeconds()
                self:waitMarker(oldest)
                wait_this = nowSeconds() - wait_started
            end
        end
        wait_seconds = wait_seconds + wait_this

        if scheduler ~= "fixed" then
            local sleep_started = nowSeconds()
            sleepMs(configured_delay)
            sleep_this = nowSeconds() - sleep_started
            sleep_seconds = sleep_seconds + sleep_this
        end

        local row = {
            submitted = submitted,
            logical = logical,
            render_ms = render_elapsed * 1000,
            refresh_ms = refresh_elapsed * 1000,
            wait_ms = wait_this * 1000,
            sleep_ms = sleep_this * 1000,
            interval_ms = interval_ms,
            lateness_ms = lateness_ms,
            skipped_before = skipped_before,
        }
        table.insert(rows, row)

        -- Sparse system telemetry only. Keeping it in memory avoids log I/O during animation.
        if submitted == 1 or submitted % 10 == 0 or logical >= frames then
            table.insert(telemetry, self:captureTelemetry(submitted, logical, row))
        end

        logical = logical + 1
    end

    if not error_text then
        if scheduler == "bounded" then
            for _, marker in ipairs(marker_queue) do
                local wait_started = nowSeconds()
                self:waitMarker(marker)
                wait_seconds = wait_seconds + (nowSeconds() - wait_started)
            end
        elseif spec.api then
            if Screen.refreshWaitForLast then Screen:refreshWaitForLast() end
        elseif last_marker and not spec.wait_each then
            self:waitMarker(last_marker)
        end
    end

    local elapsed = nowSeconds() - started
    local end_state = self:readSystemState()
    sleepMs(250)

    if error_text then
        local failure = string.format("%s: FAILED after %d frames (%s)", spec.name, submitted, error_text)
        self:appendRunLog(spec, size, frames, scheduler, failure,
            self:timingSummary(rows), telemetry, start_state, end_state,
            submitted, skipped_total)
        return failure
    end

    local divisor = math.max(1, submitted)
    local summary = string.format(
        "%s: %.0f ms total, %.1f ms/submitted frame wall, %.1f render, %.1f refresh, %.1f wait; scheduler=%s",
        spec.name, elapsed * 1000, elapsed * 1000 / divisor,
        render_seconds * 1000 / divisor, refresh_seconds * 1000 / divisor,
        wait_seconds * 1000 / divisor, scheduler)

    local timing = self:timingSummary(rows)
    if bayer_motion then
        summary = summary .. string.format("; logical=%d submitted=%d skipped=%d; %s",
            frames, submitted, skipped_total, timing)
    end
    self:appendRunLog(spec, size, frames, scheduler, summary, timing, telemetry,
        start_state, end_state, submitted, skipped_total)
    return summary
end

function MotionLab:getVisualTests()
    local common = {
        { name = "KOReader A2 (gray input, no dither)", api = "a2" },
        { name = "KOReader A2 + SW Bayer binary dither", api = "a2",
            render_mode = "ordered_binary", block_size = self.bayer_block_size },
        { name = "KOReader A2 + SW stochastic binary dither", api = "a2",
            render_mode = "stochastic_binary", block_size = 2 },

        { name = "KOReader DU (gray input, no dither)", api = "fast" },
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

    }

    for _, spec in ipairs(raw) do
        table.insert(common, spec)
    end
    return common
end

function MotionLab:writeResults(lines)
    -- Append only newly-added checkpoint lines so Run EVERYTHING does not
    -- repeatedly duplicate the full cumulative result table in the single log.
    if not self._checkpoint_count or #lines < self._checkpoint_count then
        self._checkpoint_count = 0
    end
    local first = self._checkpoint_count + 1
    if first <= #lines then
        local out = {}
        if self._checkpoint_count == 0 then
            out[#out + 1] = "----------------------------------------------------------------"
            out[#out + 1] = "CHECKPOINT " .. os.date("%Y-%m-%d %H:%M:%S")
        end
        for i = first, #lines do out[#out + 1] = lines[i] end
        self:appendLog(out)
        self._checkpoint_count = #lines
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

function MotionLab:setGifSetting(key, value)
    self[key] = value
    G_reader_settings:saveSetting("einkmotionlab_" .. key, value)
end

function MotionLab:playGif(path)
    if self._gif_loading or self._gif_player then return end
    self._gif_loading, self._gif_abort = true, false
    local loading = InfoMessage:new{ text = "Preparing GIF frames…\n\nDuring playback, tap anywhere to stop." }
    UIManager:show(loading)
    local _, _, size = self:getPatchRect(self.patch_size)
    local options = {
        path = path, refresh_mode = self.gif_mode, clock_mode = self.gif_clock,
        target_fps = math.max(1, self.target_fps),
        queue_depth = math.max(1, math.min(8, self.queue_depth)), loops = self.gif_loops,
    }
    UIManager:scheduleIn(0.1, function()
        if self._gif_abort then
            self._gif_loading = nil
            UIManager:close(loading)
            return
        end
        local started = nowSeconds()
        local ok, animation = pcall(function()
            return dofile(plugin_dir .. "gifloader.lua").load(path, size, options.refresh_mode == "gray" and "gray" or "bayer")
        end)
        options.prepare_ms = (nowSeconds() - started) * 1000
        UIManager:close(loading)
        if not ok then
            self._gif_loading = nil
            self:appendLog({ "GIF LOAD ERROR " .. os.date("%Y-%m-%d %H:%M:%S"), tostring(animation) })
            self:showInfo("Could not play GIF:\n\n" .. tostring(animation))
            return
        end
        G_reader_settings:saveSetting("einkmotionlab_last_gif", path)
        -- Let the loading dialog disappear before taking the page snapshot.
        UIManager:scheduleIn(0.1, function()
            self._gif_loading = nil
            if self._gif_abort then animation:free(); return end
            local started_ok, err = pcall(function()
                dofile(plugin_dir .. "gifplayer.lua").start(self, animation, options)
            end)
            if not started_ok then
                animation:free()
                self:showInfo("Could not start GIF playback:\n\n" .. tostring(err))
            end
        end)
    end)
end

function MotionLab:chooseGif()
    local PathChooser = require("ui/widget/pathchooser")
    local lfs = require("libs/libkoreader-lfs")
    local previous = G_reader_settings:readSetting("einkmotionlab_last_gif")
    local path = previous and previous:match("^(.*)/")
        or G_reader_settings:readSetting("home_dir") or "/mnt/us"
    if lfs.attributes(path, "mode") ~= "directory" then path = "." end
    local chooser
    local function choose(file) self:playGif(file) end
    chooser = PathChooser:new{
        title = "Tap a GIF to play", path = path,
        select_directory = false, select_file = true,
        file_filter = function(file) return file:lower():match("%.gif$") ~= nil end,
        onConfirm = choose,
        onMenuSelect = function(widget, item)
            if item.path and lfs.attributes(item.path, "mode") == "file" then
                UIManager:close(widget)
                choose(item.path)
                return true
            end
            return PathChooser.onMenuSelect(widget, item)
        end,
    }
    UIManager:show(chooser)
end

function MotionLab:onCloseDocument()
    self._gif_abort = true
    if self._gif_player then self._gif_player:finish("book closed", true) end
end

function MotionLab:gifItems()
    return {
        { text = _("Play demo GIF"), callback = function() self:playGif(plugin_dir .. "demo.gif") end },
        { text = _("Choose and play GIF…"), callback = function() self:chooseGif() end },
        { text = _("Replay last GIF"),
            enabled_func = function() return G_reader_settings:readSetting("einkmotionlab_last_gif") ~= nil end,
            callback = function()
                local path = G_reader_settings:readSetting("einkmotionlab_last_gif")
                if path then self:playGif(path) end
            end },
        { text = _("GIF refresh mode"), sub_item_table = {
            radioItem("A2 + software Bayer", function() return self.gif_mode == "a2" end,
                function() self:setGifSetting("gif_mode", "a2") end),
            radioItem("DU + software Bayer", function() return self.gif_mode == "du" end,
                function() self:setGifSetting("gif_mode", "du") end),
            radioItem("UI/AUTO grayscale", function() return self.gif_mode == "gray" end,
                function() self:setGifSetting("gif_mode", "gray") end),
        } },
        { text = _("GIF timing"), sub_item_table = {
            radioItem("Original GIF frame delays", function() return self.gif_clock == "original" end,
                function() self:setGifSetting("gif_clock", "original") end),
            radioItem("Use Fixed-clock target FPS", function() return self.gif_clock == "fixed" end,
                function() self:setGifSetting("gif_clock", "fixed") end),
        } },
        { text = _("GIF repetitions"), sub_item_table = {
            radioItem("Once", function() return self.gif_loops == 1 end,
                function() self:setGifSetting("gif_loops", 1) end),
            radioItem("3 times", function() return self.gif_loops == 3 end,
                function() self:setGifSetting("gif_loops", 3) end),
            radioItem("10 times", function() return self.gif_loops == 10 end,
                function() self:setGifSetting("gif_loops", 10) end),
        } },
    }
end

function MotionLab:addToMainMenu(menu_items)
    menu_items.einkmotionlab = {
        text = _("E-Ink Motion / Grayscale Lab"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Run GIF test"),
                sub_item_table = self:gifItems(),
            },
            {
                text = _("Diagnose renderer (screen stays still)"),
                callback = function()
                    self:runSafely("renderer diagnostic", function()
                        if Screen.refreshWaitForLast then Screen:refreshWaitForLast() end
                        return dofile(diagnostic_path).run(self)
                    end)
                end,
            },
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
                text = _("SW Bayer animation scheduler"),
                sub_item_table = {
                    radioItem("Free-running (current relative delay)",
                        function() return self.scheduler_mode == "free" end,
                        function() self:setSchedulerMode("free") end),
                    radioItem("Fixed clock (drop late logical frames)",
                        function() return self.scheduler_mode == "fixed" end,
                        function() self:setSchedulerMode("fixed") end),
                    radioItem("Bounded EPDC queue",
                        function() return self.scheduler_mode == "bounded" end,
                        function() self:setSchedulerMode("bounded") end),
                },
            },
            {
                text = _("Fixed-clock target FPS"),
                sub_item_table = {
                    radioItem("15 fps", function() return self.target_fps == 15 end, function() self:setTargetFps(15) end),
                    radioItem("20 fps", function() return self.target_fps == 20 end, function() self:setTargetFps(20) end),
                    radioItem("30 fps", function() return self.target_fps == 30 end, function() self:setTargetFps(30) end),
                    radioItem("45 fps", function() return self.target_fps == 45 end, function() self:setTargetFps(45) end),
                    radioItem("60 fps", function() return self.target_fps == 60 end, function() self:setTargetFps(60) end),
                    radioItem("90 fps", function() return self.target_fps == 90 end, function() self:setTargetFps(90) end),
                },
            },
            {
                text = _("Bounded queue depth"),
                sub_item_table = {
                    radioItem("1 update", function() return self.queue_depth == 1 end, function() self:setQueueDepth(1) end),
                    radioItem("2 updates", function() return self.queue_depth == 2 end, function() self:setQueueDepth(2) end),
                    radioItem("4 updates", function() return self.queue_depth == 4 end, function() self:setQueueDepth(4) end),
                    radioItem("8 updates", function() return self.queue_depth == 8 end, function() self:setQueueDepth(8) end),
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
