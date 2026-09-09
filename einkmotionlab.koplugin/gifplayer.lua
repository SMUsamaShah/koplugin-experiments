local Device = require("device")
local UIManager = require("ui/uimanager")
local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")
local Geom = require("ui/geometry")
local ffiUtil = require("ffi/util")
local Screen = Device.screen
local Player = InputContainer:extend{}

local function now()
    local s, us = ffiUtil.gettime()
    return s + us / 1000000
end

function Player:init()
    self.queue, self.rows = {}, {}
    self.submitted, self.skipped, self.last_logical = 0, 0, 0
    self.ends, self.cycle_time = {}, 0
    for i, frame in ipairs(self.animation.frames) do
        local delay = self.clock_mode == "fixed" and 1 / self.target_fps or frame.delay
        self.cycle_time = self.cycle_time + delay
        self.ends[i] = self.cycle_time
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen.bb:getWidth(), h = Screen.bb:getHeight() }
    self.ges_events = {
        Stop = {
            GestureRange:new{ ges = "tap", range = self.dimen },
            GestureRange:new{ ges = "hold", range = self.dimen },
            GestureRange:new{ ges = "swipe", range = self.dimen },
        },
    }
    self.key_events = { Stop = { { "Back" }, { "Home" } } }
    self.tick = function()
        if self.done then return end
        local ok, err = pcall(self.step, self)
        if not ok then self:finish("error: " .. tostring(err)) end
    end
end

function Player:paintTo(bb)
    if self.current and not self.done then
        local frame = self.animation.frames[self.current]
        bb:blitFrom(frame.bb, self.x, self.y, 0, 0, self.animation.width, self.animation.height)
    end
end

function Player:frameAt(elapsed)
    if elapsed >= self.cycle_time * self.loops then return nil end
    local cycle = math.floor(elapsed / self.cycle_time)
    local offset = elapsed - cycle * self.cycle_time
    local lo, hi = 1, #self.ends
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if offset < self.ends[mid] then hi = mid else lo = mid + 1 end
    end
    return lo, cycle * #self.ends + lo, cycle * self.cycle_time + self.ends[lo]
end

function Player:step()
    if not self.started then
        if Screen.refreshWaitForLast then Screen:refreshWaitForLast() end
        self.started = now()
    end
    if not self:frameAt(now() - self.started) then
        self.skipped = self.skipped + #self.ends * self.loops - self.last_logical
        return self:finish("complete")
    end
    -- Wait BEFORE overwriting the framebuffer and submitting another update.
    local t0 = now()
    if #self.queue >= self.queue_depth then
        local marker = table.remove(self.queue, 1)
        if self.lab:waitMarker(marker) == -1 then error("GIF refresh completion wait failed.") end
    end
    local wait_ms = (now() - t0) * 1000
    local frame_started = now()
    local index, logical, deadline = self:frameAt(frame_started - self.started)
    if not index then
        self.skipped = self.skipped + #self.ends * self.loops - self.last_logical
        return self:finish("complete")
    end
    if logical <= self.last_logical then
        UIManager:scheduleIn(math.max(0.001, self.started + deadline - now()), self.tick)
        return
    end
    self.skipped = self.skipped + logical - self.last_logical - 1
    self.last_logical, self.current = logical, index
    t0 = now()
    self:paintTo(Screen.bb)
    local render_ms = (now() - t0) * 1000
    local marker_before = Screen.marker
    t0 = now()
    if self.refresh_mode == "du" then
        Screen:refreshFast(self.x, self.y, self.animation.width, self.animation.height, false)
    elseif self.refresh_mode == "gray" then
        Screen:refreshUI(self.x, self.y, self.animation.width, self.animation.height, false)
    else
        Screen:refreshA2(self.x, self.y, self.animation.width, self.animation.height, false)
    end
    local refresh_ms = (now() - t0) * 1000
    if Screen.marker and Screen.marker ~= marker_before then
        self.queue[#self.queue + 1] = Screen.marker
    elseif Screen.refreshWaitForLast then
        -- Backends without exposed markers use a synchronous fallback.
        t0 = now()
        Screen:refreshWaitForLast()
        wait_ms = wait_ms + (now() - t0) * 1000
    end
    self.submitted = self.submitted + 1
    self.rows[#self.rows + 1] = {
        render_ms = render_ms, refresh_ms = refresh_ms, wait_ms = wait_ms,
        interval_ms = self.previous_started and (frame_started - self.previous_started) * 1000 or 0,
    }
    self.previous_started = frame_started
    UIManager:scheduleIn(math.max(0.001, self.started + deadline - now()), self.tick)
end

function Player:finish(reason, quiet, externally_closed)
    if self.done then return true end
    self.done = true
    UIManager:unschedule(self.tick)
    local elapsed = self.started and now() - self.started or 0
    local errors = {}
    local function cleanup(fn)
        local ok, err = pcall(fn)
        if not ok then errors[#errors + 1] = tostring(err) end
    end
    cleanup(function()
        for _, marker in ipairs(self.queue) do
            if self.lab:waitMarker(marker) == -1 then error("GIF final refresh wait failed.") end
        end
    end)
    cleanup(function()
        if self.snapshot then self.lab:restorePatch(self.snapshot, self.box_x, self.box_y, self.box_size) end
    end)
    cleanup(function() if self.snapshot then self.snapshot:free(); self.snapshot = nil end end)
    cleanup(function() self.animation:free() end)
    self.lab._gif_player = nil
    if not externally_closed then cleanup(function() UIManager:close(self) end) end
    UIManager:setDirty(self.lab.ui, "ui")
    local summary = string.format("GIF %s: %d submitted, %d skipped, %.2f s.",
        reason, self.submitted, self.skipped, elapsed)
    local lines = {
        "================================================================",
        "GIF RUN " .. os.date("%Y-%m-%d %H:%M:%S"),
        "plugin_version=0.1.11",
        "file=" .. (self.path:match("[^/]+$") or self.path),
        "source_frames=" .. #self.ends,
        string.format("size=%dx%d; cache_bytes=%d; prepare_ms=%.1f",
            self.animation.width, self.animation.height, self.animation.cache_bytes, self.prepare_ms),
        string.format("refresh=%s; clock=%s; target_fps=%s; queue_depth=%d; loops=%d",
            self.refresh_mode, self.clock_mode, self.target_fps, self.queue_depth, self.loops),
        "frames_prepared_before_playback=true; render_ms_measures_cached_blit=true",
        summary,
        self.lab:timingSummary(self.rows),
    }
    if #errors > 0 then
        lines[#lines + 1] = "cleanup_errors=" .. table.concat(errors, "; ")
        summary = summary .. "\n" .. table.concat(errors, "\n")
    end
    self.lab:appendLog(lines)
    if not quiet then self.lab:showInfo(summary .. "\n\nTimings saved to einkmotionlab.log.") end
    return true
end

function Player:onStop() return self:finish("stopped") end
function Player:onHome() return self:finish("stopped") end
function Player:onSuspend() return self:finish("suspended", true) end
function Player:onSetRotationMode() return self:finish("rotation changed", true) end
function Player:onCloseWidget() return self:finish("closed", true, true) end

function Player.start(lab, animation, options)
    local widget
    local ok, err = pcall(function()
        local x, y, size = lab:getPatchRect(lab.patch_size)
        widget = Player:new{
            lab = lab, animation = animation, path = options.path,
            refresh_mode = options.refresh_mode, clock_mode = options.clock_mode,
            target_fps = math.max(1, options.target_fps), queue_depth = math.max(1, options.queue_depth),
            loops = options.loops, prepare_ms = options.prepare_ms,
            box_x = x, box_y = y, box_size = size,
            x = x + math.floor((size - animation.width) / 2),
            y = y + math.floor((size - animation.height) / 2),
        }
        widget.snapshot = Screen.bb:copy()
        lab:cleanPatch(x, y, size)
        lab._gif_player = widget
        UIManager:show(widget)
        UIManager:scheduleIn(0.1, widget.tick)
    end)
    if not ok then
        if widget then widget:finish("error: " .. tostring(err))
        else animation:free(); lab:showInfo("GIF playback failed: " .. tostring(err)) end
    end
    return widget
end

return Player
