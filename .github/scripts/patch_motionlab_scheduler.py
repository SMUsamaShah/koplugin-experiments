from pathlib import Path
import re

p = Path('einkmotionlab.koplugin/main.lua')
s = p.read_text()

old = '''    self.bayer_block_size = tonumber(G_reader_settings:readSetting("einkmotionlab_bayer_block_size")) or 2
    self.raw_ok = has_mxcfb and Device:isKindle() and Device:isRex()
'''
new = '''    self.bayer_block_size = tonumber(G_reader_settings:readSetting("einkmotionlab_bayer_block_size")) or 2
    self.scheduler_mode = G_reader_settings:readSetting("einkmotionlab_scheduler_mode") or "free"
    self.target_fps = tonumber(G_reader_settings:readSetting("einkmotionlab_target_fps")) or 60
    self.queue_depth = tonumber(G_reader_settings:readSetting("einkmotionlab_queue_depth")) or 4
    self.raw_ok = has_mxcfb and Device:isKindle() and Device:isRex()
'''
assert old in s
s = s.replace(old, new, 1)

old = '    self.results_path = DataStorage:getSettingsDir() .. "/einkmotionlab-last.txt"\n'
new = old + '    self.frame_log_path = DataStorage:getSettingsDir() .. "/einkmotionlab-frames.tsv"\n'
assert old in s
s = s.replace(old, new, 1)

old = '''function MotionLab:setBayerBlockSize(v)
    self.bayer_block_size = v
    G_reader_settings:saveSetting("einkmotionlab_bayer_block_size", v)
end

function MotionLab:runSafely(label, fn)'''
new = '''function MotionLab:setBayerBlockSize(v)
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

function MotionLab:runSafely(label, fn)'''
assert old in s
s = s.replace(old, new, 1)

new_block = r'''function MotionLab:isBayerMotionTest(spec)
    return spec.render_mode == "ordered_binary"
        and (spec.api == "a2" or spec.api == "fast")
end

function MotionLab:writeFrameLog(spec, rows, scheduler, skipped_total)
    if not self:isBayerMotionTest(spec) then return end
    local f = io.open(self.frame_log_path, "w")
    if not f then return end
    f:write("# test\t", spec.name, "\n")
    f:write("# scheduler\t", scheduler, "\n")
    f:write("# target_fps\t", tostring(self.target_fps), "\n")
    f:write("# queue_depth\t", tostring(self.queue_depth), "\n")
    f:write("# skipped_logical_frames\t", tostring(skipped_total or 0), "\n")
    f:write("submitted\tlogical\trender_ms\trefresh_ms\twait_ms\tsleep_ms\tinterval_ms\tlateness_ms\tskipped_before\n")
    for _, r in ipairs(rows) do
        f:write(string.format("%d\t%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%d\n",
            r.submitted, r.logical, r.render_ms, r.refresh_ms, r.wait_ms,
            r.sleep_ms, r.interval_ms, r.lateness_ms, r.skipped_before))
    end
    f:close()
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
        self:paintNoise(x, y, size, (logical - 1) * 0.19,
            spec.block_size or self.block_size, spec.render_mode)
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

        table.insert(rows, {
            submitted = submitted,
            logical = logical,
            render_ms = render_elapsed * 1000,
            refresh_ms = refresh_elapsed * 1000,
            wait_ms = wait_this * 1000,
            sleep_ms = sleep_this * 1000,
            interval_ms = interval_ms,
            lateness_ms = lateness_ms,
            skipped_before = skipped_before,
        })

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
    self:writeFrameLog(spec, rows, scheduler, skipped_total)
    sleepMs(250)

    if error_text then
        return string.format("%s: FAILED after %d frames (%s)", spec.name, submitted, error_text)
    end

    local divisor = math.max(1, submitted)
    local summary = string.format(
        "%s: %.0f ms total, %.1f ms/submitted frame wall, %.1f render, %.1f refresh, %.1f wait; scheduler=%s",
        spec.name, elapsed * 1000, elapsed * 1000 / divisor,
        render_seconds * 1000 / divisor, refresh_seconds * 1000 / divisor,
        wait_seconds * 1000 / divisor, scheduler)

    if bayer_motion then
        summary = summary .. string.format("; logical=%d submitted=%d skipped=%d; %s; frame log: %s",
            frames, submitted, skipped_total, self:timingSummary(rows), self.frame_log_path)
    end
    return summary
end'''

pat = re.compile(r'function MotionLab:runVisualTest\(spec, size, frames\).*?\nend\n\nfunction MotionLab:getVisualTests\(\)', re.S)
m = pat.search(s)
assert m
s = s[:m.start()] + new_block + '\n\nfunction MotionLab:getVisualTests()' + s[m.end():]

anchor = '''            {
                text = _("SW Bayer block size"),
                sub_item_table = {'''
menu = '''            {
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
'''
assert anchor in s
s = s.replace(anchor, menu + anchor, 1)
p.write_text(s)

meta = Path('einkmotionlab.koplugin/_meta.lua')
m = meta.read_text()
assert 'version = "0.1.4"' in m
meta.write_text(m.replace('version = "0.1.4"', 'version = "0.1.5"', 1))

readme = Path('einkmotionlab.koplugin/README.md')
r = readme.read_text()
if '## SW Bayer scheduling diagnostics' not in r:
    r += '''\n## SW Bayer scheduling diagnostics\n\nThe A2/DU software-Bayer tests have three scheduling modes: **Free-running**, **Fixed clock** (absolute deadlines and dropped obsolete logical frames), and **Bounded EPDC queue** (caps outstanding updates and waits on the oldest marker). Target FPS and queue depth are configurable.\n\nEvery SW Bayer A2/DU run records per-frame render, refresh-call, queue-wait, sleep, interval and lateness timings to `einkmotionlab-frames.tsv`. The result also reports early/middle/late averages so progressive CPU slowdown can be distinguished from EPDC back-pressure.\n'''
    readme.write_text(r)
