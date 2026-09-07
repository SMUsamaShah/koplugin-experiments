--[[--
E-Ink Animation Lab

Experimental KOReader plugin for measuring fast E-Ink refreshes and previewing
page-turn effects on the ACTUAL book pages currently being read.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
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
    if t < 0.5 then return 4 * t * t * t end
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
    local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()
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
    end
end

local function sleepMs(ms)
    if ms and ms > 0 then
        ffiUtil.usleep(ms * 1000)
    end
end

local function restoreSnapshot(snapshot)
    if not snapshot then return end
    local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()
    Screen.bb:blitFrom(snapshot, 0, 0, 0, 0, sw, sh)
    Screen:refreshPartial(0, 0, sw, sh)
end

local function drawShadow(edge_x, shadow_w, y, h, binary)
    if shadow_w <= 0 then return end
    local sw = Screen.bb:getWidth()
    local x = math.floor(clamp(edge_x, 0, sw))
    local maxw = math.floor(math.min(shadow_w, sw - x))
    if maxw <= 0 then return end

    if binary then
        local i = 0
        while i < maxw do
            Screen.bb:paintRect(x + i, y, 1, h, BLACK)
            i = i + 5
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

local function paintSyntheticPage(bb, variant)
    local w, h = bb:getWidth(), bb:getHeight()
    bb:fill(WHITE)
    local margin = math.floor(w * 0.09)
    local top = math.floor(h * 0.10)
    local usable = w - margin * 2
    bb:paintRect(margin, top, math.floor(usable * (variant == 1 and 0.42 or 0.55)), 10, BLACK)
    bb:paintRect(margin, top + 24, math.floor(usable * 0.26), 6, GRAY)

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
        if row % 7 == 0 then y = y + gap end
        y = y + gap
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

function AnimationLab:currentPosition()
    if self.ui.paging and self.ui.paging.current_page then
        return self.ui.paging.current_page
    end
    if self.ui.rolling and self.ui.rolling.current_page then
        return self.ui.rolling.current_page
    end
    if self.ui.view and self.ui.view.state then
        return self.ui.view.state.page
    end
end

-- Capture the current visible screen, move KOReader to an adjacent real page,
-- then render the updated ReaderUI into an off-screen buffer. No forced repaint
-- happens here, so the E-Ink panel still shows the old page until our animation.
function AnimationLab:captureRealPagePair(direction)
    local old = Screen.bb:copy()
    local before = self:currentPosition()

    self.ui:handleEvent(Event:new("GotoViewRel", direction))

    local after = self:currentPosition()
    if before ~= nil and after ~= nil and before == after then
        old:free()
        return nil, nil, direction > 0
            and "Already at the last page/view."
            or "Already at the first page/view."
    end

    local new = old:copy()
    self.ui:paintTo(new, 0, 0)
    return old, new
end

function AnimationLab:makeSyntheticPair()
    local old = Screen.bb:copy()
    local new = Screen.bb:copy()
    paintSyntheticPage(old, 1)
    paintSyntheticPage(new, 2)
    return old, new
end

function AnimationLab:animatePair(old, new, style)
    local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()
    local frames = math.max(style == "curve" and 6 or 4, self.frames)
    local mode = self.mode
    local shadow = style == "plain" and 0 or math.max(18, math.floor(sw * 0.025))
    local binary = mode == "fast" or mode == "a2"
    local started = nowSeconds()

    Screen.bb:blitFrom(old, 0, 0, 0, 0, sw, sh)

    if style == "curve" then
        local band_h = math.max(24, math.floor(sh / 28))
        local curve_amp = math.floor(sw * 0.035)
        local prev_base = sw

        for i = 1, frames do
            local t = easeInOutCubic(i / frames)
            local base = math.floor(sw * (1 - t))
            local bend = math.sin(math.pi * t) * curve_amp
            local dirty_x = math.max(0, math.min(prev_base, base) - curve_amp - shadow - 4)
            local dirty_r = math.min(sw, math.max(prev_base, base) + curve_amp + shadow + 4)
            local dirty_w = dirty_r - dirty_x

            local y = 0
            while y < sh do
                local bh = math.min(band_h, sh - y)
                local yn = (y + bh * 0.5) / sh
                local bow = 4 * yn * (1 - yn)
                local edge = math.floor(clamp(base + bend * bow, 0, sw))

                local left_w = math.max(0, math.min(dirty_r, edge) - dirty_x)
                if left_w > 0 then
                    Screen.bb:blitFrom(old, dirty_x, y, dirty_x, y, left_w, bh)
                end
                local right_x = math.max(dirty_x, edge)
                local right_w = dirty_r - right_x
                if right_w > 0 then
                    Screen.bb:blitFrom(new, right_x, y, right_x, y, right_w, bh)
                end
                drawShadow(edge, shadow, y, bh, binary)
                y = y + bh
            end

            refreshRegion(mode, dirty_x, 0, dirty_w, sh)
            if self.sync_frames then waitForLast() end
            sleepMs(self.delay_ms)
            prev_base = base
        end
    else
        local prev_edge = sw
        for i = 1, frames do
            local edge = math.floor(sw * (1 - easeInOutCubic(i / frames)))
            local dirty_x = math.max(0, math.min(prev_edge, edge) - shadow - 3)
            local dirty_r = math.min(sw, math.max(prev_edge, edge) + shadow + 3)
            local dirty_w = dirty_r - dirty_x

            local left_w = math.max(0, math.min(dirty_r, edge) - dirty_x)
            if left_w > 0 then
                Screen.bb:blitFrom(old, dirty_x, 0, dirty_x, 0, left_w, sh)
            end
            local right_x = math.max(dirty_x, edge)
            local right_w = dirty_r - right_x
            if right_w > 0 then
                Screen.bb:blitFrom(new, right_x, 0, right_x, 0, right_w, sh)
            end
            if shadow > 0 then
                drawShadow(edge, shadow, 0, sh, binary)
            end

            refreshRegion(mode, dirty_x, 0, dirty_w, sh)
            if self.sync_frames then waitForLast() end
            sleepMs(self.delay_ms)
            prev_edge = edge
        end
    end

    if not self.sync_frames then waitForLast() end
    local elapsed = nowSeconds() - started

    -- Make the framebuffer exactly match the real destination page. KOReader
    -- still has that page as its current state, so normal repainting resumes
    -- from here instead of jumping back to the old page.
    Screen.bb:blitFrom(new, 0, 0, 0, 0, sw, sh)
    old:free()
    new:free()

    return elapsed, frames
end

function AnimationLab:runRealPageTurn(style, direction)
    local old, new, err = self:captureRealPagePair(direction)
    if not old then return err end

    local elapsed, frames = self:animatePair(old, new, style)
    return string.format(
        "Real %s page turn\n%s\nMode: %s\nFrames: %d\nTotal: %.0f ms\nAverage: %.1f ms/frame",
        direction > 0 and "next" or "previous",
        style == "plain" and "Plain wipe"
            or (style == "shadow" and "Wipe + moving shadow" or "Curved edge + shadow"),
        refreshName(self.mode), frames,
        elapsed * 1000, elapsed * 1000 / frames)
end

function AnimationLab:runSyntheticPreview(style)
    local original = Screen.bb:copy()
    local old, new = self:makeSyntheticPair()
    local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()

    Screen.bb:blitFrom(old, 0, 0, 0, 0, sw, sh)
    Screen:refreshPartial(0, 0, sw, sh)
    waitForLast()
    sleepMs(120)

    local elapsed, frames = self:animatePair(old, new, style)
    sleepMs(250)
    restoreSnapshot(original)
    original:free()
    UIManager:setDirty(self.ui, "ui")

    return string.format(
        "Synthetic %s\nMode: %s\nFrames: %d\nTotal: %.0f ms\nAverage: %.1f ms/frame",
        style, refreshName(self.mode), frames,
        elapsed * 1000, elapsed * 1000 / frames)
end

function AnimationLab:runMovingBox(mode)
    local snapshot = Screen.bb:copy()
    local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()
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
        local x = math.floor(left + (right - left) * easeInOutCubic(i / frames))
        local dirty_x = math.min(prev_x, x) - pad
        local dirty_r = math.max(prev_x + box, x + box) + pad
        local dirty_w = dirty_r - dirty_x

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

function AnimationLab:runWaveformComparison()
    local modes = {"a2", "fast", "ui", "partial"}
    local lines = {"Refresh comparison", ""}
    local old_delay, old_sync = self.delay_ms, self.sync_frames
    self.delay_ms = 0
    self.sync_frames = true

    for _, mode in ipairs(modes) do
        if mode ~= "a2" or Screen.refreshA2 then
            local snapshot = Screen.bb:copy()
            local sw, sh = Screen.bb:getWidth(), Screen.bb:getHeight()
            local box = math.max(48, math.floor(math.min(sw, sh) * 0.07))
            local y = math.floor(sh * 0.46)
            local x0, x1 = math.floor(sw * 0.18), math.floor(sw * 0.70)
            local frames, prev_x = 8, x0
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
            table.insert(lines, string.format("%s: %.1f ms/frame",
                refreshName(mode), elapsed * 1000 / frames))
            restoreSnapshot(snapshot)
            snapshot:free()
            sleepMs(100)
        end
    end

    self.delay_ms, self.sync_frames = old_delay, old_sync
    UIManager:setDirty(self.ui, "ui")
    return table.concat(lines, "\n")
end

local function radioItem(text, checked, callback)
    return {
        text = text,
        radio = true,
        checked_func = checked,
        callback = callback,
    }
end

local function previewItems(self, direction)
    return {
        {
            text = _("Plain wipe"),
            callback = function()
                self:runSafely("real plain wipe",
                    function() return self:runRealPageTurn("plain", direction) end)
            end,
        },
        {
            text = _("Wipe + moving shadow"),
            callback = function()
                self:runSafely("real shadow wipe",
                    function() return self:runRealPageTurn("shadow", direction) end)
            end,
        },
        {
            text = _("Curved edge + shadow"),
            callback = function()
                self:runSafely("real curved turn",
                    function() return self:runRealPageTurn("curve", direction) end)
            end,
        },
    }
end

function AnimationLab:addToMainMenu(menu_items)
    menu_items.animationlab = {
        text = _("E-Ink Animation Lab"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Turn ACTUAL next book page"),
                sub_item_table = previewItems(self, 1),
            },
            {
                text = _("Turn ACTUAL previous book page"),
                sub_item_table = previewItems(self, -1),
            },
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
                    self:runSafely("waveform comparison",
                        function() return self:runWaveformComparison() end)
                end,
            },
            {
                text = _("Synthetic diagnostics"),
                sub_item_table = {
                    {
                        text = _("Plain wipe"),
                        callback = function()
                            self:runSafely("synthetic plain",
                                function() return self:runSyntheticPreview("plain") end)
                        end,
                    },
                    {
                        text = _("Wipe + moving shadow"),
                        callback = function()
                            self:runSafely("synthetic shadow",
                                function() return self:runSyntheticPreview("shadow") end)
                        end,
                    },
                    {
                        text = _("Curved edge + shadow"),
                        callback = function()
                            self:runSafely("synthetic curve",
                                function() return self:runSyntheticPreview("curve") end)
                        end,
                    },
                },
            },
            {
                text = _("Refresh mode"),
                sub_item_table = {
                    radioItem(_("A2 (fastest, 1-bit)"),
                        function() return self.mode == "a2" end,
                        function() self:setMode("a2") end),
                    radioItem(_("Fast / DU"),
                        function() return self.mode == "fast" end,
                        function() self:setMode("fast") end),
                    radioItem(_("UI"),
                        function() return self.mode == "ui" end,
                        function() self:setMode("ui") end),
                    radioItem(_("Partial"),
                        function() return self.mode == "partial" end,
                        function() self:setMode("partial") end),
                },
            },
            {
                text = _("Frames"),
                sub_item_table = {
                    radioItem("6", function() return self.frames == 6 end, function() self:setFrames(6) end),
                    radioItem("8", function() return self.frames == 8 end, function() self:setFrames(8) end),
                    radioItem("10", function() return self.frames == 10 end, function() self:setFrames(10) end),
                    radioItem("12", function() return self.frames == 12 end, function() self:setFrames(12) end),
                    radioItem("16", function() return self.frames == 16 end, function() self:setFrames(16) end),
                },
            },
            {
                text = _("Frame delay"),
                sub_item_table = {
                    radioItem("0 ms", function() return self.delay_ms == 0 end, function() self:setDelay(0) end),
                    radioItem("4 ms", function() return self.delay_ms == 4 end, function() self:setDelay(4) end),
                    radioItem("8 ms", function() return self.delay_ms == 8 end, function() self:setDelay(8) end),
                    radioItem("12 ms", function() return self.delay_ms == 12 end, function() self:setDelay(12) end),
                    radioItem("20 ms", function() return self.delay_ms == 20 end, function() self:setDelay(20) end),
                },
            },
            {
                text = _("Wait for each refresh"),
                checked_func = function() return self.sync_frames end,
                callback = function() self:setSyncFrames(not self.sync_frames) end,
                help_text = _("On = serialized timing. Off = smoothest pipelined animation."),
            },
        },
    }
end

return AnimationLab
