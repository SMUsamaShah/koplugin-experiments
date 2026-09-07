--[[--
E-Ink Animation Lab

A deliberately small experimental KOReader plugin for measuring animation-like
refreshes on real E-Ink hardware. It writes directly to Screen.bb and refreshes
only the dirty region, like Finger Ink's low-latency drawing path.

The plugin never changes the document. Every test snapshots the framebuffer,
runs directly on that snapshot, then restores it and asks KOReader for a normal
repaint.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_GRAY
local DARK_GRAY = Blitbuffer.COLOR_DARK_GRAY
local LIGHT_GRAY = Blitbuffer.COLOR_LIGHT_GRAY

local AnimationLab = WidgetContainer:extend{
    name = "animationlab",
    is_doc_only = true,
}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function nowSeconds()
    local s, us = ffiUtil.gettime()
    return s + us / 1000000
end

local function easeInOutCubic(t)
    if t < 0.5 then
        return 4 * t * t * t
    end
    local a = -2 * t + 2
    return 1 - (a * a * a) / 2
end

local function refreshName(mode)
    if mode == "a2" then return "A2" end
    if mode == "fast" then return "Fast / DU" end
    if mode == "ui" then return "UI" end
    return "Partial"
end

local function refreshRegion(mode, x, y, w, h)
    local sw = Screen.bb:getWidth()
    local sh = Screen.bb:getHeight()
    x = math.floor(clamp(x, 0, sw))
    y = math.floor(clamp(y, 0, sh))
    w = math.floor(clamp(w, 0, sw - x))
    h = math.floor(clamp(h, 0, sh - y))
    if w <= 0 or h <= 0 then return end

    if mode == "a2" and Screen.refreshA2 then
        Screen:refreshA2(x, y, w, h)
    elseif mode == "fast" and Screen.refreshFast then
        Screen:refreshFast(x, y, w, h)
    elseif mode == "ui" and Screen.refreshUI then
        Screen:refreshUI(x, y, w, h)
    else
        Screen:refreshPartial(x, y, w, h)
    end
end

local function waitForLast()
    if Screen.refreshWaitForLast then
        Screen:refreshWaitForLast()
        return true
    end
    return false
end

local function sleepMs(ms)
    if ms and ms > 0 then
        ffiUtil.usleep(ms * 1000)
    end
end

local function restoreSnapshot(snapshot)
    if not snapshot then return end
    local sw = Screen.bb:getWidth()
    local sh = Screen.bb:getHeight()
    Screen.bb:blitFrom(snapshot, 0, 0, 0, 0, sw, sh)
    Screen:refreshPartial(0, 0, sw, sh)
end

local function paintSyntheticPage(bb, variant)
    local w = bb:getWidth()
    local h = bb:getHeight()
    bb:fill(WHITE)

    local margin = math.floor(w * 0.09)
    local top = math.floor(h * 0.10)
    local usable = w - margin * 2

    -- Header / chapter marker.
    bb:paintRect(margin, top, math.floor(usable * (variant == 1 and 0.42 or 0.55)), 10, BLACK)
    bb:paintRect(margin, top + 24, math.floor(usable * 0.26), 6, GRAY)

    -- Text-like rows. Alternating lengths make movement and ghosting obvious.
    local y = top + 78
    local line_h = math.max(4, math.floor(h / 300))
    local gap = math.max(17, math.floor(h / 55))
    local row = 0
    while y < h - top do
        row = row + 1
        local frac
        if variant == 1 then
            frac = ({0.92, 0.84, 0.95, 0.73, 0.88})[(row - 1) % 5 + 1]
        else
            frac = ({0.78, 0.94, 0.68, 0.89, 0.82, 0.96})[(row - 1) % 6 + 1]
        end
        bb:paintRect(margin, y, math.floor(usable * frac), line_h, BLACK)
        if row % 7 == 0 then
            y = y + gap
        end
        y = y + gap
    end

    -- Page number block in a different corner per page.
    local pw = math.max(24, math.floor(w * 0.04))
    local ph = math.max(8, math.floor(h * 0.007))
    local px = variant == 1 and margin or (w - margin - pw)
    bb:paintRect(px, h - math.floor(top * 0.55), pw, ph, DARK_GRAY)
end

local function drawShadow(edge_x, shadow_w, y, h, fast_monochrome)
    if shadow_w <= 0 then return end
    local sw = Screen.bb:getWidth()
    local x = clamp(edge_x, 0, sw)
    local maxw = math.min(shadow_w, sw - x)
    if maxw <= 0 then return end

    if fast_monochrome then
        -- A2/DU are happiest with binary pixels. Use a sparse vertical hatch
        -- instead of asking the waveform to reproduce smooth greys.
        local step = 5
        local i = 0
        while i < maxw do
            Screen.bb:paintRect(x + i, y, 1, h, BLACK)
            i = i + step
        end
        Screen.bb:paintRect(x, y, math.min(2, maxw), h, BLACK)
    else
        local a = math.max(1, math.floor(maxw * 0.20))
        local b = math.max(1, math.floor(maxw * 0.35))
        local c = maxw - a - b
        Screen.bb:paintRect(x, y, a, h, DARK_GRAY)
        Screen.bb:paintRect(x + a, y, b, h, GRAY)
        if c > 0 then
            Screen.bb:paintRect(x + a + b, y, c, h, LIGHT_GRAY)
        end
    end
end

function AnimationLab:init()
    self.mode = G_reader_settings:readSetting("animationlab_mode") or "fast"
    self.frames = tonumber(G_reader_settings:readSetting("animationlab_frames")) or 10
    self.delay_ms = tonumber(G_reader_settings:readSetting("animationlab_delay_ms")) or 8
    self.sync_frames = G_reader_settings:isTrue("animationlab_sync_frames")
    self.ui.menu:registerToMainMenu(self)
end

function AnimationLab:showInfo(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function AnimationLab:setMode(mode)
    self.mode = mode
    G_reader_settings:saveSetting("animationlab_mode", mode)
end

function AnimationLab:setFrames(frames)
    self.frames = frames
    G_reader_settings:saveSetting("animationlab_frames", frames)
end

function AnimationLab:setDelay(ms)
    self.delay_ms = ms
    G_reader_settings:saveSetting("animationlab_delay_ms", ms)
end

function AnimationLab:setSyncFrames(sync)
    self.sync_frames = sync and true or false
    G_reader_settings:saveSetting("animationlab_sync_frames", self.sync_frames)
end

function AnimationLab:runSafely(label, fn)
    -- Let the menu finish closing before touching the framebuffer directly.
    UIManager:nextTick(function()
        local ok, result = pcall(fn)
        if not ok then
            logger.warn("AnimationLab " .. label .. " failed:", result)
            self:showInfo("E-Ink Animation Lab: " .. label .. " failed\n\n" .. tostring(result))
        elseif result then
            self:showInfo(result)
        end
    end)
end

function AnimationLab:runMovingBox(mode)
    local snapshot = Screen.bb:copy()
    local sw = Screen.bb:getWidth()
    local sh = Screen.bb:getHeight()
    local box = math.max(48, math.floor(math.min(sw, sh) * 0.075))
    local pad = 6
    local left = math.floor(sw * 0.08)
    local right = sw - left - box
    local y = math.floor(sh * 0.45)
    local frames = math.max(8, self.frames * 2)

    local prev_x = left
    Screen.bb:paintRect(prev_x, y, box, box, BLACK)
    refreshRegion(mode, prev_x, y, box, box)
    if self.sync_frames then waitForLast() end

    local started = nowSeconds()
    for i = 1, frames do
        local t = i / frames
        local x = math.floor(left + (right - left) * easeInOutCubic(t))
        local dirty_x = math.min(prev_x, x) - pad
        local dirty_r = math.max(prev_x + box, x + box) + pad
        local dirty_w = dirty_r - dirty_x

        -- Restore exactly the union of the old and new box region, then draw.
        Screen.bb:blitFrom(snapshot, dirty_x, y - pad, dirty_x, y - pad,
            dirty_w, box + pad * 2)
        Screen.bb:paintRect(x, y, box, box, BLACK)
        refreshRegion(mode, dirty_x, y - pad, dirty_w, box + pad * 2)
        if self.sync_frames then waitForLast() end
        sleepMs(self.delay_ms)
        prev_x = x
    end
    if not self.sync_frames then waitForLast() end
    local elapsed = nowSeconds() - started

    restoreSnapshot(snapshot)
    snapshot:free()
    UIManager:setDirty(self.ui, "ui")

    return string.format(
        "Moving-box benchmark\nMode: %s\nFrames: %d\nDelay: %d ms\nSynchronized: %s\nTotal: %.0f ms\nAverage: %.1f ms/frame",
        refreshName(mode), frames, self.delay_ms,
        self.sync_frames and "yes" or "no",
        elapsed * 1000, elapsed * 1000 / frames)
end

function AnimationLab:makePagePair()
    local old = Screen.bb:copy()
    local new = Screen.bb:copy()
    paintSyntheticPage(old, 1)
    paintSyntheticPage(new, 2)
    return old, new
end

function AnimationLab:preparePageDemo(old)
    local sw = Screen.bb:getWidth()
    local sh = Screen.bb:getHeight()
    Screen.bb:blitFrom(old, 0, 0, 0, 0, sw, sh)
    Screen:refreshPartial(0, 0, sw, sh)
    waitForLast()
    sleepMs(120)
end

function AnimationLab:finishPageDemo(original, old, new)
    restoreSnapshot(original)
    original:free()
    old:free()
    new:free()
    UIManager:setDirty(self.ui, "ui")
end

function AnimationLab:runWipePreview(with_shadow)
    local original = Screen.bb:copy()
    local old, new = self:makePagePair()
    local sw = Screen.bb:getWidth()
    local sh = Screen.bb:getHeight()
    local frames = math.max(4, self.frames)
    local mode = self.mode
    local shadow = with_shadow and math.max(18, math.floor(sw * 0.025)) or 0

    self:preparePageDemo(old)
    local prev_edge = sw
    local started = nowSeconds()

    for i = 1, frames do
        local t = easeInOutCubic(i / frames)
        local edge = math.floor(sw * (1 - t))
        local dirty_x = math.max(0, math.min(prev_edge, edge) - shadow - 3)
        local dirty_r = math.min(sw, math.max(prev_edge, edge) + shadow + 3)
        local dirty_w = dirty_r - dirty_x

        -- Reconstruct the dirty strip from the two authoritative page buffers.
        local left_w = math.max(0, math.min(dirty_r, edge) - dirty_x)
        if left_w > 0 then
            Screen.bb:blitFrom(old, dirty_x, 0, dirty_x, 0, left_w, sh)
        end
        local right_x = math.max(dirty_x, edge)
        local right_w = dirty_r - right_x
        if right_w > 0 then
            Screen.bb:blitFrom(new, right_x, 0, right_x, 0, right_w, sh)
        end
        if with_shadow then
            drawShadow(edge, shadow, 0, sh, mode == "fast" or mode == "a2")
        end

        refreshRegion(mode, dirty_x, 0, dirty_w, sh)
        if self.sync_frames then waitForLast() end
        sleepMs(self.delay_ms)
        prev_edge = edge
    end

    if not self.sync_frames then waitForLast() end
    local elapsed = nowSeconds() - started
    sleepMs(250)
    self:finishPageDemo(original, old, new)

    return string.format(
        "%s page-turn preview\nMode: %s\nFrames: %d\nTotal: %.0f ms\nAverage: %.1f ms/frame",
        with_shadow and "Shadowed wipe" or "Plain wipe",
        refreshName(mode), frames,
        elapsed * 1000, elapsed * 1000 / frames)
end

function AnimationLab:runCurvedCurlPreview()
    local original = Screen.bb:copy()
    local old, new = self:makePagePair()
    local sw = Screen.bb:getWidth()
    local sh = Screen.bb:getHeight()
    local frames = math.max(6, self.frames)
    local mode = self.mode
    local shadow = math.max(20, math.floor(sw * 0.028))
    local band_h = math.max(24, math.floor(sh / 28))
    local curve_amp = math.floor(sw * 0.035)

    self:preparePageDemo(old)
    local prev_base = sw
    local started = nowSeconds()

    for i = 1, frames do
        local raw_t = i / frames
        local t = easeInOutCubic(raw_t)
        local base = math.floor(sw * (1 - t))
        local bend = math.sin(math.pi * t) * curve_amp
        local dirty_x = math.max(0, math.min(prev_base, base) - curve_amp - shadow - 4)
        local dirty_r = math.min(sw, math.max(prev_base, base) + curve_amp + shadow + 4)
        local dirty_w = dirty_r - dirty_x

        local y = 0
        while y < sh do
            local bh = math.min(band_h, sh - y)
            local yn = (y + bh * 0.5) / sh
            -- A soft bowed edge: strongest displacement around mid-screen.
            local bow = 4 * yn * (1 - yn)
            local edge = math.floor(base + bend * bow)
            edge = clamp(edge, 0, sw)

            local left_w = math.max(0, math.min(dirty_r, edge) - dirty_x)
            if left_w > 0 then
                Screen.bb:blitFrom(old, dirty_x, y, dirty_x, y, left_w, bh)
            end
            local right_x = math.max(dirty_x, edge)
            local right_w = dirty_r - right_x
            if right_w > 0 then
                Screen.bb:blitFrom(new, right_x, y, right_x, y, right_w, bh)
            end
            drawShadow(edge, shadow, y, bh, mode == "fast" or mode == "a2")
            y = y + bh
        end

        refreshRegion(mode, dirty_x, 0, dirty_w, sh)
        if self.sync_frames then waitForLast() end
        sleepMs(self.delay_ms)
        prev_base = base
    end

    if not self.sync_frames then waitForLast() end
    local elapsed = nowSeconds() - started
    sleepMs(300)
    self:finishPageDemo(original, old, new)

    return string.format(
        "Curved-curl preview\nMode: %s\nFrames: %d\nBands: %d px\nTotal: %.0f ms\nAverage: %.1f ms/frame",
        refreshName(mode), frames, band_h,
        elapsed * 1000, elapsed * 1000 / frames)
end

function AnimationLab:runWaveformComparison()
    local modes = {"a2", "fast", "ui", "partial"}
    local lines = {"Refresh comparison", ""}
    local previous_mode = self.mode
    local previous_delay = self.delay_ms
    local previous_sync = self.sync_frames

    -- Synchronized measurements are more useful for comparing waveform latency.
    self.delay_ms = 0
    self.sync_frames = true

    for _, mode in ipairs(modes) do
        if mode ~= "a2" or Screen.refreshA2 then
            local snapshot = Screen.bb:copy()
            local sw = Screen.bb:getWidth()
            local sh = Screen.bb:getHeight()
            local box = math.max(48, math.floor(math.min(sw, sh) * 0.07))
            local y = math.floor(sh * 0.46)
            local x0 = math.floor(sw * 0.18)
            local x1 = math.floor(sw * 0.70)
            local frames = 8
            local prev_x = x0
            local started = nowSeconds()
            for i = 1, frames do
                local x = math.floor(x0 + (x1 - x0) * (i / frames))
                local dx = math.min(prev_x, x) - 4
                local dr = math.max(prev_x + box, x + box) + 4
                Screen.bb:blitFrom(snapshot, dx, y - 4, dx, y - 4, dr - dx, box + 8)
                Screen.bb:paintRect(x, y, box, box, BLACK)
                refreshRegion(mode, dx, y - 4, dr - dx, box + 8)
                waitForLast()
                prev_x = x
            end
            local elapsed = nowSeconds() - started
            table.insert(lines, string.format("%s: %.1f ms/frame", refreshName(mode), elapsed * 1000 / frames))
            restoreSnapshot(snapshot)
            snapshot:free()
            sleepMs(100)
        end
    end

    self.mode = previous_mode
    self.delay_ms = previous_delay
    self.sync_frames = previous_sync
    UIManager:setDirty(self.ui, "ui")
    return table.concat(lines, "\n")
end

local function radioItem(self, text, current_func, callback)
    return {
        text = text,
        radio = true,
        checked_func = current_func,
        callback = callback,
    }
end

function AnimationLab:addToMainMenu(menu_items)
    menu_items.animationlab = {
        text = _("E-Ink Animation Lab"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Moving box benchmark"),
                callback = function()
                    local mode = self.mode
                    self:runSafely("moving box", function() return self:runMovingBox(mode) end)
                end,
            },
            {
                text = _("Compare refresh modes"),
                callback = function()
                    self:runSafely("waveform comparison", function() return self:runWaveformComparison() end)
                end,
            },
            {
                text = _("Page-turn previews"),
                sub_item_table = {
                    {
                        text = _("Plain wipe"),
                        callback = function()
                            self:runSafely("plain wipe", function() return self:runWipePreview(false) end)
                        end,
                    },
                    {
                        text = _("Wipe + moving shadow"),
                        callback = function()
                            self:runSafely("shadowed wipe", function() return self:runWipePreview(true) end)
                        end,
                    },
                    {
                        text = _("Curved edge + shadow"),
                        callback = function()
                            self:runSafely("curved curl", function() return self:runCurvedCurlPreview() end)
                        end,
                    },
                },
            },
            {
                text = _("Refresh mode"),
                sub_item_table = {
                    radioItem(self, _("A2 (fastest, 1-bit)"),
                        function() return self.mode == "a2" end,
                        function() self:setMode("a2") end),
                    radioItem(self, _("Fast / DU"),
                        function() return self.mode == "fast" end,
                        function() self:setMode("fast") end),
                    radioItem(self, _("UI"),
                        function() return self.mode == "ui" end,
                        function() self:setMode("ui") end),
                    radioItem(self, _("Partial"),
                        function() return self.mode == "partial" end,
                        function() self:setMode("partial") end),
                },
            },
            {
                text = _("Frames"),
                sub_item_table = {
                    radioItem(self, "6", function() return self.frames == 6 end, function() self:setFrames(6) end),
                    radioItem(self, "8", function() return self.frames == 8 end, function() self:setFrames(8) end),
                    radioItem(self, "10", function() return self.frames == 10 end, function() self:setFrames(10) end),
                    radioItem(self, "12", function() return self.frames == 12 end, function() self:setFrames(12) end),
                    radioItem(self, "16", function() return self.frames == 16 end, function() self:setFrames(16) end),
                },
            },
            {
                text = _("Frame delay"),
                sub_item_table = {
                    radioItem(self, "0 ms", function() return self.delay_ms == 0 end, function() self:setDelay(0) end),
                    radioItem(self, "4 ms", function() return self.delay_ms == 4 end, function() self:setDelay(4) end),
                    radioItem(self, "8 ms", function() return self.delay_ms == 8 end, function() self:setDelay(8) end),
                    radioItem(self, "12 ms", function() return self.delay_ms == 12 end, function() self:setDelay(12) end),
                    radioItem(self, "20 ms", function() return self.delay_ms == 20 end, function() self:setDelay(20) end),
                },
            },
            {
                text = _("Wait for each refresh"),
                checked_func = function() return self.sync_frames end,
                callback = function() self:setSyncFrames(not self.sync_frames) end,
                help_text = _("Serializes refreshes so timing is meaningful. Leave off to test the smoothest pipelined animation."),
            },
        },
    }
end

return AnimationLab
