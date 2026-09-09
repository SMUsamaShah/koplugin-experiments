from pathlib import Path
import re

p = Path('einkmotionlab.koplugin/main.lua')
s = p.read_text()

old = '''    self.results_path = DataStorage:getSettingsDir() .. "/einkmotionlab-last.txt"\n    self.frame_log_path = DataStorage:getSettingsDir() .. "/einkmotionlab-frames.tsv"\n'''
new = '''    self.log_path = DataStorage:getSettingsDir() .. "/einkmotionlab.log"\n    self.results_path = self.log_path\n'''
assert old in s, 'old log paths not found'
s = s.replace(old, new, 1)

marker = '''function MotionLab:onDispatcherRegisterActions()\n'''
assert marker in s
helpers = r'''local function readTextFile(path)
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
    local freq = tonumber(firstReadable({
        "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq",
        "/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_cur_freq",
        "/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq",
        "/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_cur_freq",
    }))
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
    local zones = {}
    for i = 0, 9 do
        local raw = readTextFile(string.format("/sys/class/thermal/thermal_zone%d/temp", i))
        local n = tonumber(raw)
        if n then
            if math.abs(n) > 1000 then n = n / 1000 end
            zones[#zones + 1] = string.format("tz%d=%.1fC", i, n)
            if not hottest or n > hottest then hottest = n end
        end
    end
    for i = 0, 3 do
        local raw = readTextFile(string.format("/sys/class/hwmon/hwmon%d/temp1_input", i))
        local n = tonumber(raw)
        if n then
            if math.abs(n) > 1000 then n = n / 1000 end
            zones[#zones + 1] = string.format("hwmon%d=%.1fC", i, n)
            if not hottest or n > hottest then hottest = n end
        end
    end

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
        "plugin_version=0.1.8",
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
    return {
        submitted = submitted,
        logical = logical,
        row = row,
        state = self:readSystemState(),
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
    lines[#lines + 1] = "-- SAMPLES (first, every 10 submitted frames, last) --"
    if telemetry and #telemetry > 0 then
        for _, sample in ipairs(telemetry) do
            local r = sample.row or {}
            lines[#lines + 1] = string.format(
                "submitted=%d logical=%d render=%.1fms refresh=%.1fms wait=%.1fms sleep=%.1fms interval=%.1fms late=%.1fms | %s",
                sample.submitted or 0, sample.logical or 0,
                r.render_ms or 0, r.refresh_ms or 0, r.wait_ms or 0,
                r.sleep_ms or 0, r.interval_ms or 0, r.lateness_ms or 0,
                self:systemStateText(sample.state))
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

'''
s = s.replace(marker, helpers + marker, 1)

old = '''        if not ok then\n            logger.warn("EInkMotionLab " .. label .. " failed:", result)\n            self:showInfo("E-Ink Motion Lab: " .. label .. " failed\\n\\n" .. tostring(result))\n'''
new = '''        if not ok then\n            logger.warn("EInkMotionLab " .. label .. " failed:", result)\n            local lines = {\n                "================================================================",\n                "ERROR " .. os.date("%Y-%m-%d %H:%M:%S"),\n                "operation=" .. tostring(label),\n                "message=" .. tostring(result),\n                "-- SETTINGS --",\n            }\n            for _, line in ipairs(self:currentSettingsLines()) do lines[#lines + 1] = line end\n            lines[#lines + 1] = "-- SYSTEM --"\n            lines[#lines + 1] = self:systemStateText(self:readSystemState())\n            self:appendLog(lines)\n            self:showInfo("E-Ink Motion Lab: " .. label .. " failed\\n\\n" .. tostring(result))\n'''
assert old in s, 'runSafely block not found'
s = s.replace(old, new, 1)

# Replace TSV writer with no per-frame file writer; timingSummary remains.
pat = re.compile(r'function MotionLab:writeFrameLog\(spec, rows, scheduler, skipped_total\).*?\nend\n\nlocal function avgMetric', re.S)
assert pat.search(s), 'writeFrameLog block not found'
s = pat.sub('local function avgMetric', s, count=1)

old = '''    self:cleanPatch(x, y, size)\n\n    local bayer_motion = self:isBayerMotionTest(spec)\n'''
new = '''    self:cleanPatch(x, y, size)\n\n    local start_state = self:readSystemState()\n    local telemetry = {}\n    local bayer_motion = self:isBayerMotionTest(spec)\n'''
assert old in s, 'run start not found'
s = s.replace(old, new, 1)

old = '''        local render_started = nowSeconds()\n        self:paintNoise(x, y, size, (logical - 1) * 0.19,\n            spec.block_size or self.block_size, spec.render_mode)\n'''
new = '''        local render_started = nowSeconds()\n        -- Read the Bayer block size at execution time, not when the menu was built.\n        local render_block = bayer_motion and self.bayer_block_size\n            or (spec.block_size or self.block_size)\n        self:paintNoise(x, y, size, (logical - 1) * 0.19,\n            render_block, spec.render_mode)\n'''
assert old in s, 'paintNoise call not found'
s = s.replace(old, new, 1)

old = '''        table.insert(rows, {\n            submitted = submitted,\n            logical = logical,\n            render_ms = render_elapsed * 1000,\n            refresh_ms = refresh_elapsed * 1000,\n            wait_ms = wait_this * 1000,\n            sleep_ms = sleep_this * 1000,\n            interval_ms = interval_ms,\n            lateness_ms = lateness_ms,\n            skipped_before = skipped_before,\n        })\n\n        logical = logical + 1\n'''
new = '''        local row = {\n            submitted = submitted,\n            logical = logical,\n            render_ms = render_elapsed * 1000,\n            refresh_ms = refresh_elapsed * 1000,\n            wait_ms = wait_this * 1000,\n            sleep_ms = sleep_this * 1000,\n            interval_ms = interval_ms,\n            lateness_ms = lateness_ms,\n            skipped_before = skipped_before,\n        }\n        table.insert(rows, row)\n\n        -- Sparse system telemetry only. Keeping it in memory avoids log I/O during animation.\n        if submitted == 1 or submitted % 10 == 0 or logical >= frames then\n            table.insert(telemetry, self:captureTelemetry(submitted, logical, row))\n        end\n\n        logical = logical + 1\n'''
assert old in s, 'row insert block not found'
s = s.replace(old, new, 1)

old = '''    local elapsed = nowSeconds() - started\n    self:writeFrameLog(spec, rows, scheduler, skipped_total)\n    sleepMs(250)\n\n    if error_text then\n        return string.format("%s: FAILED after %d frames (%s)", spec.name, submitted, error_text)\n    end\n'''
new = '''    local elapsed = nowSeconds() - started\n    local end_state = self:readSystemState()\n    sleepMs(250)\n\n    if error_text then\n        local failure = string.format("%s: FAILED after %d frames (%s)", spec.name, submitted, error_text)\n        self:appendRunLog(spec, size, frames, scheduler, failure,\n            self:timingSummary(rows), telemetry, start_state, end_state,\n            submitted, skipped_total)\n        return failure\n    end\n'''
assert old in s, 'post-run frame log block not found'
s = s.replace(old, new, 1)

old = '''    if bayer_motion then\n        summary = summary .. string.format("; logical=%d submitted=%d skipped=%d; %s; frame log: %s",\n            frames, submitted, skipped_total, self:timingSummary(rows), self.frame_log_path)\n    end\n    return summary\nend\n'''
new = '''    local timing = self:timingSummary(rows)\n    if bayer_motion then\n        summary = summary .. string.format("; logical=%d submitted=%d skipped=%d; %s",\n            frames, submitted, skipped_total, timing)\n    end\n    self:appendRunLog(spec, size, frames, scheduler, summary, timing, telemetry,\n        start_state, end_state, submitted, skipped_total)\n    return summary\nend\n'''
assert old in s, 'summary frame-log block not found'
s = s.replace(old, new, 1)

# Preserve only one plain log file for suite/capability checkpoints as well.
pat = re.compile(r'function MotionLab:writeResults\(lines\)\n.*?\nend\n\nfunction MotionLab:capabilityLines', re.S)
m = pat.search(s)
assert m, 'writeResults function not found'
replacement = r'''function MotionLab:writeResults(lines)
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

function MotionLab:capabilityLines'''
s = pat.sub(replacement, s, count=1)

# Version bump.
meta = Path('einkmotionlab.koplugin/_meta.lua')
m = meta.read_text()
assert 'version = "0.1.7"' in m
meta.write_text(m.replace('version = "0.1.7"', 'version = "0.1.8"', 1))

# README: replace old dual-file logging descriptions with the single log design.
readme = Path('einkmotionlab.koplugin/README.md')
r = readme.read_text()
r = r.replace(
    'The suite saves results incrementally to `einkmotionlab-last.txt` in KOReader\'s settings directory. This is intentional: the most experimental pause test runs last, so earlier timing results should already be on disk even if that probe misbehaves.',
    'All diagnostics now append to one plain-text history file, `einkmotionlab.log`, in KOReader\'s settings directory. Every visual test records all current Motion Lab settings, the final timing result, start/end system state, and sparse CPU/temperature telemetry. Suite checkpoints are appended incrementally so earlier data survives even if a later experimental probe misbehaves.'
)
r = r.replace('2. `einkmotionlab-last.txt`;', '2. `einkmotionlab.log`;')
r = r.replace(
    'Every SW Bayer A2/DU run records per-frame render, refresh-call, queue-wait, sleep, interval and lateness timings to `einkmotionlab-frames.tsv`. The result also reports early/middle/late averages so progressive CPU slowdown can be distinguished from EPDC back-pressure.',
    'The result dialog still reports the useful early/middle/late render, refresh, wait and interval averages. There is no longer a per-frame TSV. Instead, `einkmotionlab.log` stores one readable block per test with every current setting, the final result, CPU frequency/governor/range, thermal readings, load and available memory at start/end, plus sparse samples at frame 1, every 10 submitted frames, and the final frame. Samples are collected in memory and written only after the animation to avoid disk I/O affecting the test. The SW Bayer block size is also resolved at execution time so changing it immediately affects already-open test menus.'
)
readme.write_text(r)

p.write_text(s)
print('patched Motion Lab logging')
